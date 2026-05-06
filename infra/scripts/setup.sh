#!/usr/bin/env bash
set -euo pipefail

# Run this once on a fresh Ubuntu host. Installs Docker, configures secrets,
# builds the custom Caddy binary, and deploys the stacks you choose.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

prompt_required() {
  local -n _ref=$1
  local msg="$2"
  while true; do
    read -rp "  $msg: " _ref
    [[ -n "$_ref" ]] && break
    warn "This field is required."
  done
}

prompt_secret() {
  local -n _ref=$1
  local msg="$2"
  while true; do
    read -rsp "  $msg: " _ref; echo
    [[ -n "$_ref" ]] && break
    warn "This field is required."
  done
}

prompt_yn() {
  local -n _ref=$1
  local msg="$2"
  local reply
  read -rp "  $msg [y/N] " reply
  [[ "${reply,,}" == "y" ]] && _ref="y" || _ref="n"
}

copy_secret() {
  local src="$1" dst="$2"
  if [[ -f "$dst" ]]; then
    warn "$(basename "$dst") already exists — skipping"
  else
    cp "$src" "$dst"
    ok "$(basename "$dst") created"
  fi
}

# ── sanity checks ─────────────────────────────────────────────────────────────

[[ "$(uname)" == "Linux" ]] || die "This script must be run on Linux."
[[ "$EUID" -ne 0 ]]        || die "Run as your normal user, not root."

# ── gather all input ──────────────────────────────────────────────────────────

bold "Homelab setup"
echo "All questions are asked upfront. Setup begins after you answer them."
echo ""

step "Domain"
prompt_required HOMELAB_DOMAIN "Root domain (e.g. yourdomain.com)"

step "DNS provider credentials (Porkbun)"
info "Used by Caddy to issue TLS certificates via DNS challenge."
prompt_secret PORKBUN_API_KEY    "Porkbun API key"
prompt_secret PORKBUN_API_SECRET "Porkbun API secret"

step "Stacks to deploy (core is always included)"
prompt_yn DEPLOY_OBSERVABILITY "Observability — Grafana, Prometheus, Homepage?"
prompt_yn DEPLOY_MEDIA         "Media — Plex, Radarr, Sonarr, qBittorrent?"
prompt_yn DEPLOY_APPS          "Apps — Calibre, FileBrowser?"
prompt_yn DEPLOY_HOME          "Home — Home Assistant, Matter Server?"

if [[ "$DEPLOY_OBSERVABILITY" == "y" ]]; then
  step "Grafana"
  prompt_secret GRAFANA_PASSWORD "Admin password"
fi

if [[ "$DEPLOY_MEDIA" == "y" ]]; then
  step "Media paths"
  info "Bind-mounted into Plex, qBittorrent, Radarr, and Sonarr."
  prompt_required MEDIA_PATH    "Path to media drive (e.g. /mnt/media)"
  prompt_required TORRENTS_PATH "Path to torrents directory (e.g. /mnt/torrents)"
  prompt_yn       NVIDIA_GPU    "NVIDIA GPU available for Plex transcoding?"
fi

if [[ "$DEPLOY_APPS" == "y" ]]; then
  step "Calibre"
  prompt_required BOOKS_PATH "Path to books directory (e.g. /mnt/media/books)"
fi

NEED_TZ="n"
[[ "$DEPLOY_HOME" == "y" || "$DEPLOY_APPS" == "y" ]] && NEED_TZ="y"
if [[ "$NEED_TZ" == "y" ]]; then
  step "Timezone"
  info "Applied to Home Assistant and Calibre. Format: Region/City"
  info "See: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"
  prompt_required TIMEZONE "Timezone (e.g. Europe/London)"
fi

ZIGBEE_DEVICE=""
if [[ "$DEPLOY_HOME" == "y" ]]; then
  step "Zigbee dongle (Home Assistant)"
  info "Leave blank to skip — edit docker-compose.yml manually later."
  info "To find your device: ls /dev/serial/by-id/"
  read -rp "  Device path (or Enter to skip): " ZIGBEE_DEVICE
fi

echo ""
bold "Starting setup..."

# ── prerequisites ─────────────────────────────────────────────────────────────

step "Prerequisites"
sudo apt-get update -q
sudo apt-get install -y -q git curl python3
ok "git, curl, python3 ready"

# ── docker ────────────────────────────────────────────────────────────────────

step "Docker"
DOCKER_NEWLY_INSTALLED="n"
if command -v docker &>/dev/null; then
  ok "Docker already installed"
else
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
  DOCKER_NEWLY_INSTALLED="y"
  ok "Docker installed"
fi

if ! groups "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  ok "Added $USER to docker group"
  warn "Group change takes effect in new shells — deploys will use 'sg docker' to work around this."
fi

# Wrapper so deploys work even if we just added the user to docker group.
run_deploy() {
  local stack="$1"
  if sg docker true 2>/dev/null; then
    sg docker -c "REPO_ROOT='$REPO_ROOT' '$REPO_ROOT/infra/scripts/deploy-stack.sh' '$stack'"
  else
    REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/infra/scripts/deploy-stack.sh" "$stack"
  fi
}

# ── directories ───────────────────────────────────────────────────────────────

step "Base directories"
sudo mkdir -p \
  /opt/homelab/secrets/core \
  /opt/homelab/secrets/observability \
  /opt/homelab/data \
  /opt/homelab/caddy
sudo chown -R "$USER:$USER" /opt/homelab
ok "Created /opt/homelab hierarchy"

# ── secrets ───────────────────────────────────────────────────────────────────

step "Secrets"
copy_secret "$REPO_ROOT/infra/secrets/examples/core/caddy.env.example"           /opt/homelab/secrets/core/caddy.env
copy_secret "$REPO_ROOT/infra/secrets/examples/core/forgejo.env.example"          /opt/homelab/secrets/core/forgejo.env
copy_secret "$REPO_ROOT/infra/secrets/examples/observability/grafana.env.example" /opt/homelab/secrets/observability/grafana.env

info "Writing credentials..."

# caddy.env
sed -i "s|yourdomain\.com|${HOMELAB_DOMAIN}|g"                                   /opt/homelab/secrets/core/caddy.env
sed -i "s|^PORKBUN_API_KEY=.*|PORKBUN_API_KEY=${PORKBUN_API_KEY}|"              /opt/homelab/secrets/core/caddy.env
sed -i "s|^PORKBUN_API_SECRET=.*|PORKBUN_API_SECRET=${PORKBUN_API_SECRET}|"     /opt/homelab/secrets/core/caddy.env

# forgejo.env
sed -i "s|yourdomain\.com|${HOMELAB_DOMAIN}|g" /opt/homelab/secrets/core/forgejo.env
sed -i "s|^USER_UID=.*|USER_UID=$(id -u)|"     /opt/homelab/secrets/core/forgejo.env
sed -i "s|^USER_GID=.*|USER_GID=$(id -g)|"     /opt/homelab/secrets/core/forgejo.env

# grafana.env
sed -i "s|yourdomain\.com|${HOMELAB_DOMAIN}|g" /opt/homelab/secrets/observability/grafana.env
if [[ "$DEPLOY_OBSERVABILITY" == "y" ]]; then
  sed -i "s|^GF_SECURITY_ADMIN_PASSWORD=.*|GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}|" /opt/homelab/secrets/observability/grafana.env
fi
ok "Secrets configured"

# ── compose file patches ──────────────────────────────────────────────────────

if [[ "$DEPLOY_MEDIA" == "y" ]]; then
  step "Patching media compose"
  MEDIA_COMPOSE="$REPO_ROOT/infra/docker/compose/media/docker-compose.yml"
  sed -i "s|/mnt/media|${MEDIA_PATH}|g"       "$MEDIA_COMPOSE"
  sed -i "s|/mnt/torrents|${TORRENTS_PATH}|g" "$MEDIA_COMPOSE"
  if [[ "$NVIDIA_GPU" != "y" ]]; then
    python3 - "$MEDIA_COMPOSE" <<'PYEOF'
import sys, re
path = sys.argv[1]
text = open(path).read()
# Remove the deploy.resources GPU reservation block
text = re.sub(
    r'\s+deploy:\n\s+resources:\n\s+reservations:\n\s+devices:\n'
    r'\s+- driver: nvidia\n\s+count: all\n\s+capabilities: \[gpu\]\n',
    '\n', text
)
# Remove runtime: nvidia line
text = re.sub(r'\s+runtime: nvidia\n', '\n', text)
open(path, 'w').write(text)
PYEOF
    ok "NVIDIA config removed from media compose"
  fi
  ok "Media compose patched"
fi

if [[ "$DEPLOY_APPS" == "y" ]]; then
  step "Patching apps compose"
  APPS_COMPOSE="$REPO_ROOT/infra/docker/compose/apps/docker-compose.yml"
  sed -i "s|Africa/Johannesburg|${TIMEZONE}|g" "$APPS_COMPOSE"
  sed -i "s|/mnt/media/books|${BOOKS_PATH}|g"  "$APPS_COMPOSE"
  ok "Apps compose patched"
fi

if [[ "$DEPLOY_HOME" == "y" ]]; then
  step "Patching home compose"
  HOME_COMPOSE="$REPO_ROOT/infra/docker/compose/home/docker-compose.yml"
  sed -i "s|Africa/Johannesburg|${TIMEZONE}|g" "$HOME_COMPOSE"
  if [[ -n "$ZIGBEE_DEVICE" ]]; then
    sed -i "s|/dev/serial/by-id/[^:]*|${ZIGBEE_DEVICE}|g" "$HOME_COMPOSE"
    ok "Zigbee device set to $ZIGBEE_DEVICE"
  else
    warn "Zigbee device not set — update $HOME_COMPOSE manually before deploying."
  fi
  ok "Home compose patched"
fi

# ── trim Caddyfile to selected stacks ─────────────────────────────────────────

step "Trimming Caddyfile"
SKIP_STACKS=()
[[ "$DEPLOY_OBSERVABILITY" != "y" ]] && SKIP_STACKS+=(observability)
[[ "$DEPLOY_MEDIA" != "y" ]]         && SKIP_STACKS+=(media)
[[ "$DEPLOY_APPS" != "y" ]]          && SKIP_STACKS+=(apps)
[[ "$DEPLOY_HOME" != "y" ]]          && SKIP_STACKS+=(home)

if [[ "${#SKIP_STACKS[@]}" -gt 0 ]]; then
  python3 - "$REPO_ROOT/infra/docker/config/caddy/Caddyfile" "${SKIP_STACKS[@]}" <<'PYEOF'
import sys
path, *skip = sys.argv[1], sys.argv[2:]
skip = set(skip)
lines = open(path).readlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.strip().startswith('# stack:'):
        stack = line.strip().split('# stack:')[1].strip()
        if stack in skip:
            i += 1  # skip the comment line
            depth = 0
            while i < len(lines):
                for ch in lines[i]:
                    if ch == '{': depth += 1
                    elif ch == '}': depth -= 1
                i += 1
                if depth <= 0:
                    break
            # drop trailing blank line
            if i < len(lines) and not lines[i].strip():
                i += 1
            continue
    out.append(line)
    i += 1
open(path, 'w').write(''.join(out))
PYEOF
  ok "Removed blocks for: ${SKIP_STACKS[*]}"
else
  ok "All stacks selected — Caddyfile unchanged"
fi

# ── build custom Caddy binary ─────────────────────────────────────────────────

step "Building Caddy (with Porkbun DNS plugin)"
if [[ -f /opt/homelab/caddy/caddy ]]; then
  ok "Binary already exists — skipping build"
else
  info "Installing Go via snap (apt golang is too old for xcaddy)..."
  sudo snap install go --classic

  export PATH="$PATH:$(go env GOPATH)/bin"

  info "Installing xcaddy..."
  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

  info "Building (this takes a few minutes)..."
  xcaddy build \
    --with github.com/caddy-dns/porkbun \
    --output /opt/homelab/caddy/caddy

  ok "Caddy binary built"
fi

if [[ ! -f /opt/homelab/caddy/Dockerfile ]]; then
  cat > /opt/homelab/caddy/Dockerfile <<'DOCKERFILE'
FROM ubuntu:22.04
COPY caddy /usr/bin/caddy
ENTRYPOINT ["/usr/bin/caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
DOCKERFILE
  ok "Dockerfile written"
fi

# ── free port 53 for AdGuard ──────────────────────────────────────────────────

step "Freeing port 53 for AdGuard"
if grep -q "^DNSStubListener=no" /etc/systemd/resolved.conf 2>/dev/null; then
  ok "Already configured"
else
  echo "DNSStubListener=no" | sudo tee -a /etc/systemd/resolved.conf > /dev/null
  sudo systemctl restart systemd-resolved
  ok "systemd-resolved updated"
fi

# ── deploy ────────────────────────────────────────────────────────────────────

step "Deploying core"
run_deploy core

[[ "$DEPLOY_OBSERVABILITY" == "y" ]] && { step "Deploying observability"; run_deploy observability; }
[[ "$DEPLOY_MEDIA"         == "y" ]] && { step "Deploying media";         run_deploy media;         }
[[ "$DEPLOY_APPS"          == "y" ]] && { step "Deploying apps";          run_deploy apps;          }
[[ "$DEPLOY_HOME"          == "y" ]] && { step "Deploying home";          run_deploy home;          }

# ── remaining manual steps ────────────────────────────────────────────────────

LAN_IP="$(hostname -I | awk '{print $1}')"

echo ""
bold "Done. Three things still require manual setup:"
echo ""
echo "1. AdGuard Home — open http://${LAN_IP}:3002 and configure:"
echo "   • Filters → DNS rewrites: *.${HOMELAB_DOMAIN} → ${LAN_IP}"
echo "   • Settings → DNS settings: upstream DNS → https://dns.cloudflare.com/dns-query"
echo "   Then point your router's DHCP DNS field at ${LAN_IP}."
echo ""
echo "2. DNS A record in Porkbun:"
echo "   Type: A  |  Host: *.${HOMELAB_DOMAIN}  |  Answer: <your server IP>"
echo "   Use your Tailscale IP if you're using Tailscale, otherwise your public IP."
echo "   Once this is live Caddy will issue TLS certs automatically."
echo ""
echo "3. Forgejo Actions runner — once Forgejo is up at https://forgejo.${HOMELAB_DOMAIN}:"
echo "   Site Administration → Actions → Runners → create a runner token, then"
echo "   install and register the runner on this host."
echo ""
if [[ "$DEPLOY_HOME" == "y" && -z "$ZIGBEE_DEVICE" ]]; then
  echo "4. Zigbee device — update the 'devices:' entry in:"
  echo "   $REPO_ROOT/infra/docker/compose/home/docker-compose.yml"
  echo "   Then redeploy: REPO_ROOT=$REPO_ROOT $REPO_ROOT/infra/scripts/deploy-stack.sh home"
  echo ""
fi
if [[ "$DOCKER_NEWLY_INSTALLED" == "y" ]]; then
  echo "Note: Docker was installed during this run. Log out and back in to make"
  echo "the docker group membership permanent (no sudo needed for docker commands)."
  echo ""
fi
