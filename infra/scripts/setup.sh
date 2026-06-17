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

prompt_default() {
  local -n _ref=$1
  local msg="$2"
  local default="$3"
  read -rp "  $msg [$default]: " _ref
  if [[ -z "$_ref" ]]; then
    _ref="$default"
  fi
  return 0
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

ensure_dir() {
  local path="$1" label="$2"
  if [[ -d "$path" ]]; then return; fi
  warn "$path doesn't exist — creating it for $label."
  warn "If you have media on a separate drive, ctrl-C and mount it first."
  sudo mkdir -p "$path"
  sudo chown "$USER:$USER" "$path"
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

# Recent lscr.io/linuxserver/qbittorrent images print a one-time random
# admin password to stdout on first start instead of using adminadmin.
# Pull it out so we can show it in the final summary. Empty result on
# timeout (image too old, or user already set a permanent password).
get_qbt_temp_password() {
  local tries=0 pw=""
  while [[ $tries -lt 30 ]]; do
    pw=$(sudo docker logs qbittorrent 2>&1 \
      | grep -oE 'temporary password is provided for this session: [^[:space:]]+' \
      | tail -1 | awk '{print $NF}')
    if [[ -n "$pw" ]]; then
      echo "$pw"
      return 0
    fi
    sleep 1
    tries=$((tries + 1))
  done
  return 0
}

# Upstream filebrowser/filebrowser also auto-generates a random admin
# password on first start (no more admin/admin). Grep it from the
# container's stdout: "User 'admin' initialized with randomly generated password: <pw>"
get_filebrowser_temp_password() {
  local tries=0 pw=""
  while [[ $tries -lt 30 ]]; do
    pw=$(sudo docker logs filebrowser 2>&1 \
      | grep -oE "User 'admin' initialized with randomly generated password: [^[:space:]]+" \
      | tail -1 | awk '{print $NF}')
    if [[ -n "$pw" ]]; then
      echo "$pw"
      return 0
    fi
    sleep 1
    tries=$((tries + 1))
  done
  return 0
}

# Wait for any background apt/dpkg process (typically unattended-upgrades on
# a freshly booted system) to release its locks before we try to install.
wait_for_apt() {
  local waited=0
  while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if [[ $waited -eq 0 ]]; then
      info "Waiting for another apt/dpkg process to release the lock (likely unattended-upgrades on a freshly booted host)..."
    fi
    sleep 5
    waited=$((waited + 5))
    if [[ $waited -ge 300 ]]; then
      die "Timed out after 5 min waiting for apt/dpkg lock. Run 'ps auxf | grep -E apt\\\\|dpkg' to see what's holding it."
    fi
  done
  if [[ $waited -gt 0 ]]; then
    ok "Lock released after ${waited}s"
  fi
  return 0
}

# ── sanity checks ─────────────────────────────────────────────────────────────

[[ "$(uname)" == "Linux" ]] || die "This script must be run on Linux."
[[ "$EUID" -ne 0 ]]        || die "Run as your normal user, not root."
command -v openssl >/dev/null || die "openssl is required for secret generation."

if [[ "$REPO_ROOT" != "/opt/homelab/repo" ]]; then
  warn "Running from $REPO_ROOT, not /opt/homelab/repo."
  warn "Forgejo CI workflows hardcode REPO_ROOT=/opt/homelab/repo — CI will break"
  warn "unless the repo lives at that path. Recommended fix:"
  warn "  sudo mkdir -p /opt/homelab && sudo chown \$USER:\$USER /opt/homelab"
  warn "  git clone <repo-url> /opt/homelab/repo"
  warn "  bash /opt/homelab/repo/infra/scripts/setup.sh"
  read -rp "  Continue anyway? [y/N] " _reply
  [[ "${_reply,,}" == "y" ]] || exit 1
fi

# ── gather all input ──────────────────────────────────────────────────────────

bold "Homelab setup"
echo "All questions are asked upfront. Setup begins after you answer them."
echo ""

step "Domain (optional)"
info "If you have a domain with Porkbun DNS, services get TLS via Let's Encrypt"
info "and clean URLs like https://adguard.yourdomain.com."
info "Leave blank to skip — services will be reachable at http://<LAN-IP>:<port>"
info "and Caddy will not be deployed."
read -rp "  Root domain (or Enter to skip): " HOMELAB_DOMAIN
HAS_DOMAIN="n"
PORKBUN_API_KEY=""
PORKBUN_API_SECRET=""
if [[ -n "$HOMELAB_DOMAIN" ]]; then
  HAS_DOMAIN="y"
  step "DNS provider credentials (Porkbun)"
  info "Used by Caddy to issue TLS certificates via DNS challenge."
  prompt_secret PORKBUN_API_KEY    "Porkbun API key"
  prompt_secret PORKBUN_API_SECRET "Porkbun API secret"
else
  warn "No domain — Caddy/TLS will be skipped. Services accessible by IP+port."
fi

LAN_IP="$(hostname -I | awk '{print $1}')"
[[ -z "$LAN_IP" ]] && die "Could not determine LAN IP via 'hostname -I'."

step "Stacks to deploy (core is always included)"
prompt_yn DEPLOY_OBSERVABILITY "Observability — Grafana, Prometheus, Homepage?"
prompt_yn DEPLOY_MEDIA         "Media — Plex, Radarr, Sonarr, qBittorrent?"
prompt_yn DEPLOY_APPS          "Apps — Calibre, FileBrowser?"
prompt_yn DEPLOY_HOME          "Home — Home Assistant, Matter Server?"

if [[ "$DEPLOY_OBSERVABILITY" == "y" ]]; then
  step "Grafana"
  info "Sets the password for Grafana's built-in 'admin' user. You'll use it"
  info "to log in to the Grafana UI after deploy (default: http://<server>:3001"
  info "or https://grafana.<your-domain> if you set a domain above)."
  prompt_secret GRAFANA_PASSWORD "Admin password"
fi

if [[ "$DEPLOY_MEDIA" == "y" ]]; then
  step "Media paths"
  info "Bind-mounted into Plex, qBittorrent, Radarr, and Sonarr."
  info "A separate mounted drive is ideal for production (media is big), but"
  info "any directory works — one Raspberry Pi with a single SD card is fine."
  info "Paths that don't exist yet will be created."
  prompt_default MEDIA_PATH    "Path to media directory"    "/opt/homelab/data/media"
  prompt_default TORRENTS_PATH "Path to torrents directory" "/opt/homelab/data/torrents"
  prompt_yn      NVIDIA_GPU    "NVIDIA GPU available for Plex transcoding?"
fi

if [[ "$DEPLOY_APPS" == "y" ]]; then
  step "Calibre"
  info "Directory where your ebooks live (or will live). Will be created if it"
  info "doesn't exist."
  prompt_default BOOKS_PATH "Path to books directory" "/opt/homelab/data/books"
fi

NEED_TZ="n"
[[ "$DEPLOY_HOME" == "y" || "$DEPLOY_APPS" == "y" ]] && NEED_TZ="y"
if [[ "$NEED_TZ" == "y" ]]; then
  step "Timezone"
  info "Applied to Home Assistant and Calibre. Format: Region/City"
  info "See: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"
  while true; do
    prompt_required TIMEZONE "Timezone (e.g. Europe/London)"
    if [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
      break
    fi
    warn "'$TIMEZONE' isn't a valid timezone — try Europe/London, America/New_York, Africa/Johannesburg, Asia/Tokyo, etc."
  done
fi

ZIGBEE_DEVICE=""
if [[ "$DEPLOY_HOME" == "y" ]]; then
  step "Zigbee dongle (Home Assistant)"

  ZIGBEE_DETECTED=()
  if [[ -d /dev/serial/by-id ]]; then
    while IFS= read -r _line; do
      ZIGBEE_DETECTED+=("$_line")
    done < <(ls /dev/serial/by-id/ 2>/dev/null)
  fi

  if [[ ${#ZIGBEE_DETECTED[@]} -eq 0 ]]; then
    info "No USB serial devices detected in /dev/serial/by-id/."
    info "Plug in your Zigbee dongle and re-run, or leave blank to skip"
    info "and edit infra/docker/compose/home/docker-compose.yml later."
    read -rp "  Device path (or Enter to skip): " ZIGBEE_DEVICE
  elif [[ ${#ZIGBEE_DETECTED[@]} -eq 1 ]]; then
    info "Detected one USB serial device in /dev/serial/by-id/:"
    info "  ${ZIGBEE_DETECTED[0]}"
    read -rp "  Use this as the Zigbee dongle? [Y/n] " _reply
    if [[ "${_reply,,}" == "n" ]]; then
      read -rp "  Device path (or Enter to skip): " ZIGBEE_DEVICE
    else
      ZIGBEE_DEVICE="${ZIGBEE_DETECTED[0]}"
    fi
  else
    info "Detected multiple USB serial devices in /dev/serial/by-id/:"
    for _i in "${!ZIGBEE_DETECTED[@]}"; do
      info "  [$((_i + 1))] ${ZIGBEE_DETECTED[$_i]}"
    done
    info "  [0]  None / enter manually / skip"
    while true; do
      read -rp "  Pick a device (number): " _choice
      if [[ "$_choice" == "0" ]]; then
        read -rp "  Device path (or Enter to skip): " ZIGBEE_DEVICE
        break
      elif [[ "$_choice" =~ ^[0-9]+$ ]] && [[ $_choice -ge 1 && $_choice -le ${#ZIGBEE_DETECTED[@]} ]]; then
        ZIGBEE_DEVICE="${ZIGBEE_DETECTED[$((_choice - 1))]}"
        break
      else
        warn "Invalid choice — pick 0-${#ZIGBEE_DETECTED[@]}."
      fi
    done
  fi
fi

echo ""
bold "Starting setup..."

# ── prerequisites ─────────────────────────────────────────────────────────────

step "Prerequisites"
wait_for_apt
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
  wait_for_apt
  curl -fsSL https://get.docker.com | sudo sh
  DOCKER_NEWLY_INSTALLED="y"
  ok "Docker installed"

  # Docker 29.x throws "RWLayer is unexpectedly nil" on the first compose up
  # after install. Empirically a plain systemctl restart isn't enough — the
  # overlay2 storage state from get.docker.com's first-boot seeding leaves the
  # daemon in a wedged state. Stopping everything, wiping /var/lib/{docker,
  # containerd}, and starting fresh sidesteps the issue. Safe because nothing
  # of value has been written yet.
  info "Resetting Docker storage to dodge overlay2 init bug..."
  sudo systemctl stop docker docker.socket containerd 2>/dev/null || true
  sudo rm -rf /var/lib/docker /var/lib/containerd
  sudo systemctl start docker
  for _ in {1..30}; do
    sudo docker info >/dev/null 2>&1 && break
    sleep 1
  done
  ok "Docker daemon ready"
fi

if ! groups "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  ok "Added $USER to docker group"
  warn "Group change takes effect in new shells — deploys will use 'sg docker' to work around this."
fi

# ── NVIDIA Container Toolkit ──────────────────────────────────────────────────

# Only needed for Plex hardware transcoding in the media stack. Without this
# package, Docker doesn't know about the `nvidia` runtime even if the host
# driver is installed — `docker compose up` will error with
# "unknown or invalid runtime name: nvidia".
if [[ "${DEPLOY_MEDIA:-n}" == "y" && "${NVIDIA_GPU:-n}" == "y" ]]; then
  step "NVIDIA Container Toolkit"
  if ! command -v nvidia-smi &>/dev/null; then
    die "nvidia-smi not found — install the NVIDIA driver first (e.g. 'sudo ubuntu-drivers install') or answer 'n' to the NVIDIA GPU prompt."
  fi
  if sudo docker info 2>/dev/null | grep -qE "Runtimes:.*nvidia"; then
    ok "NVIDIA Docker runtime already configured"
  else
    info "Installing nvidia-container-toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
      sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    wait_for_apt
    sudo apt-get update -q
    sudo apt-get install -y -q nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    for _ in {1..30}; do
      sudo docker info >/dev/null 2>&1 && break
      sleep 1
    done
    ok "nvidia-container-toolkit installed and Docker runtime configured"
  fi
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
if [[ "$HAS_DOMAIN" == "y" ]]; then
  copy_secret "$REPO_ROOT/infra/secrets/examples/core/caddy.env.example"           /opt/homelab/secrets/core/caddy.env
fi
copy_secret "$REPO_ROOT/infra/secrets/examples/core/forgejo.env.example"           /opt/homelab/secrets/core/forgejo.env

if [[ "$DEPLOY_OBSERVABILITY" == "y" ]]; then
  copy_secret "$REPO_ROOT/infra/secrets/examples/observability/grafana.env.example"  /opt/homelab/secrets/observability/grafana.env
  copy_secret "$REPO_ROOT/infra/secrets/examples/observability/homepage.env.example" /opt/homelab/secrets/observability/homepage.env
fi

info "Writing credentials..."

# forgejo.env always written; UID/GID always set.
sed -i "s|^USER_UID=.*|USER_UID=$(id -u)|"     /opt/homelab/secrets/core/forgejo.env
sed -i "s|^USER_GID=.*|USER_GID=$(id -g)|"     /opt/homelab/secrets/core/forgejo.env

if [[ "$HAS_DOMAIN" == "y" ]]; then
  # caddy.env
  sed -i "s|yourdomain\.com|${HOMELAB_DOMAIN}|g"                                /opt/homelab/secrets/core/caddy.env
  sed -i "s|^PORKBUN_API_KEY=.*|PORKBUN_API_KEY=${PORKBUN_API_KEY}|"           /opt/homelab/secrets/core/caddy.env
  sed -i "s|^PORKBUN_API_SECRET=.*|PORKBUN_API_SECRET=${PORKBUN_API_SECRET}|"  /opt/homelab/secrets/core/caddy.env

  # forgejo.env — domain URLs
  sed -i "s|yourdomain\.com|${HOMELAB_DOMAIN}|g" /opt/homelab/secrets/core/forgejo.env
else
  # forgejo.env — point at LAN IP so generated links work without a domain
  sed -i "s|^FORGEJO__server__DOMAIN=.*|FORGEJO__server__DOMAIN=${LAN_IP}|"            /opt/homelab/secrets/core/forgejo.env
  sed -i "s|^FORGEJO__server__ROOT_URL=.*|FORGEJO__server__ROOT_URL=http://${LAN_IP}:3000/|" /opt/homelab/secrets/core/forgejo.env
  sed -i "s|^FORGEJO__server__SSH_DOMAIN=.*|FORGEJO__server__SSH_DOMAIN=${LAN_IP}|"    /opt/homelab/secrets/core/forgejo.env
fi

if [[ "$DEPLOY_OBSERVABILITY" == "y" ]]; then
  sed -i "s|^GF_SECURITY_ADMIN_PASSWORD=.*|GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}|" /opt/homelab/secrets/observability/grafana.env
  if [[ "$HAS_DOMAIN" == "y" ]]; then
    sed -i "s|yourdomain\.com|${HOMELAB_DOMAIN}|g" /opt/homelab/secrets/observability/grafana.env
    sed -i "s|yourdomain\.com|${HOMELAB_DOMAIN}|g" \
      "$REPO_ROOT/infra/docker/compose/observability/docker-compose.yml"
  else
    sed -i "s|^GF_SERVER_ROOT_URL=.*|GF_SERVER_ROOT_URL=http://${LAN_IP}:3001|" /opt/homelab/secrets/observability/grafana.env
    # Homepage's host check needs to allow IP-based access. Wildcard is fine on a private LAN/Tailscale.
    sed -i "s|HOMEPAGE_ALLOWED_HOSTS=.*|HOMEPAGE_ALLOWED_HOSTS=*|" \
      "$REPO_ROOT/infra/docker/compose/observability/docker-compose.yml"
  fi
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
    # Accept either bare device name (per `ls /dev/serial/by-id/`) or full
    # path. Strip any prefix the user typed and re-prepend it ourselves so
    # the compose entry is always /dev/serial/by-id/<name>:/dev/zigbee.
    ZIGBEE_DEVICE="${ZIGBEE_DEVICE#/dev/serial/by-id/}"
    sed -i "s|/dev/serial/by-id/[^:]*|/dev/serial/by-id/${ZIGBEE_DEVICE}|g" "$HOME_COMPOSE"
    ok "Zigbee device set to /dev/serial/by-id/$ZIGBEE_DEVICE"
  else
    warn "Zigbee device not set — update $HOME_COMPOSE manually before deploying."
  fi
  ok "Home compose patched"
fi

# ── rewrite domain-baked URLs to IP+port (no-domain mode) ─────────────────────

if [[ "$HAS_DOMAIN" != "y" ]]; then
  step "Rewriting domain-baked URLs to IP+port"
  PORT_MAP_FILES=()
  [[ "$DEPLOY_OBSERVABILITY" == "y" ]] && PORT_MAP_FILES+=("$REPO_ROOT/infra/docker/config/homepage/services.yaml")
  [[ "$DEPLOY_HOME" == "y" ]]          && PORT_MAP_FILES+=("$REPO_ROOT/infra/docker/config/homeassistant/configuration.yaml")

  if [[ "${#PORT_MAP_FILES[@]}" -gt 0 ]]; then
    python3 - "$LAN_IP" "${PORT_MAP_FILES[@]}" <<'PYEOF'
import sys, re
lan_ip = sys.argv[1]
paths = sys.argv[2:]

# Subdomain → host port for direct service access (no Caddy).
PORTS = {
    "adguard":       3002,
    "forgejo":       3000,
    "portainer":     9443,
    "homepage":      3003,
    "prometheus":    9090,
    "grafana":       3001,
    "calibre":       8185,
    "filebrowser":   8081,
    "homeassistant": 8123,
    "qbittorrent":   8080,
    "radarr":        7878,
    "sonarr":        8989,
    "prowlarr":      9696,
    "flaresolverr":  8191,
    "plex":          32400,
}

# Portainer and Calibre serve over https only (self-signed certs); everything
# else is plain http.
HTTPS_SUBDOMAINS = {"portainer", "calibre"}
def replace(m):
    sub = m.group(1)
    port = PORTS.get(sub)
    if port is None:
        return m.group(0)  # leave unknown subdomains alone
    scheme = "https" if sub in HTTPS_SUBDOMAINS else "http"
    return f"{scheme}://{lan_ip}:{port}"

pattern = re.compile(r"https?://([a-zA-Z0-9-]+)\.yourdomain\.com")
for path in paths:
    with open(path) as f:
        text = f.read()
    new_text = pattern.sub(replace, text)
    if new_text != text:
        with open(path, "w") as f:
            f.write(new_text)
PYEOF
    ok "URLs rewritten in: $(printf '%s\n' "${PORT_MAP_FILES[@]}" | xargs -n1 basename | tr '\n' ' ')"
  else
    ok "No domain-baked config files to rewrite (no observability/home stacks selected)"
  fi
fi

if [[ "$HAS_DOMAIN" == "y" ]]; then
  # ── trim Caddyfile to selected stacks ───────────────────────────────────────

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

  # ── build custom Caddy binary ───────────────────────────────────────────────

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
FROM ubuntu:24.04
COPY caddy /usr/bin/caddy
ENTRYPOINT ["/usr/bin/caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
DOCKERFILE
    ok "Dockerfile written"
  fi
else
  # ── no domain: strip Caddy from core compose ────────────────────────────────

  step "Removing Caddy service from core compose (no-domain mode)"
  python3 - "$REPO_ROOT/infra/docker/compose/core/docker-compose.yml" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).readlines()
out = []
i = 0
# Drop the top-level `caddy:` service block: it starts at indent 2 with "caddy:"
# and ends just before the next sibling at the same indent.
while i < len(lines):
    line = lines[i]
    if line.startswith('  caddy:'):
        i += 1
        while i < len(lines):
            nxt = lines[i]
            # Stop when we hit the next top-level service (2-space indent, non-blank)
            # or a non-indented section header (volumes:, networks:, etc.).
            if nxt and not nxt.startswith(' ') and nxt.strip():
                break
            if nxt.startswith('  ') and not nxt.startswith('    ') and nxt.strip() and not nxt.lstrip().startswith('#'):
                break
            i += 1
        continue
    out.append(line)
    i += 1
open(path, 'w').write(''.join(out))
PYEOF
  ok "Caddy removed from core/docker-compose.yml"
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

if [[ "$DEPLOY_OBSERVABILITY" == "y" ]]; then
  step "Deploying observability"
  run_deploy observability
fi

if [[ "$DEPLOY_MEDIA" == "y" ]]; then
  ensure_dir "$MEDIA_PATH"    "media stack"
  ensure_dir "$TORRENTS_PATH" "media stack (torrents)"
  step "Deploying media"
  run_deploy media
fi

if [[ "$DEPLOY_APPS" == "y" ]]; then
  ensure_dir "$BOOKS_PATH" "apps stack (books)"
  step "Deploying apps"
  run_deploy apps
fi

if [[ "$DEPLOY_HOME" == "y" ]]; then
  step "Deploying home"
  run_deploy home
fi

# ── remaining manual steps ────────────────────────────────────────────────────

# Capture qBittorrent's and filebrowser's first-boot temporary passwords while
# the containers are still on their initial run, so we can surface them in the
# summary below.
QBT_TEMP_PW=""
FB_TEMP_PW=""
if [[ "$DEPLOY_MEDIA" == "y" ]]; then
  QBT_TEMP_PW=$(get_qbt_temp_password)
fi
if [[ "$DEPLOY_APPS" == "y" ]]; then
  FB_TEMP_PW=$(get_filebrowser_temp_password)
fi

echo ""
if [[ "$HAS_DOMAIN" == "y" ]]; then
  bold "Done. Three things still require manual setup:"
  echo ""
  echo "1. AdGuard Home — first time only, open http://${LAN_IP}:3030 to run the"
  echo "   initial setup wizard (accept the default Admin Web Interface port: 80)."
  echo "   Once that completes, AdGuard's UI moves to http://${LAN_IP}:3002 — open"
  echo "   that and configure:"
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
else
  bold "Done. Services are reachable at:"
  echo ""
  echo "  AdGuard Home    http://${LAN_IP}:3030 (first-time setup wizard)"
  echo "                  http://${LAN_IP}:3002 (after wizard completes)"
  echo "  Forgejo         http://${LAN_IP}:3000"
  echo "  Portainer       https://${LAN_IP}:9443"
  [[ "$DEPLOY_OBSERVABILITY" == "y" ]] && {
    echo "  Homepage        http://${LAN_IP}:3003"
    echo "  Grafana         http://${LAN_IP}:3001"
    echo "  Prometheus      http://${LAN_IP}:9090"
  }
  [[ "$DEPLOY_MEDIA" == "y" ]] && {
    echo "  Plex            http://${LAN_IP}:32400/web"
    echo "  qBittorrent     http://${LAN_IP}:8080"
    if [[ -n "$QBT_TEMP_PW" ]]; then
      echo "                  user: admin  |  temp password: ${QBT_TEMP_PW}"
      echo "                  (rotates on container restart — set a real one at"
      echo "                   Tools → Options → Web UI before restarting)"
    fi
    echo "  Radarr          http://${LAN_IP}:7878"
    echo "  Sonarr          http://${LAN_IP}:8989"
    echo "  Prowlarr        http://${LAN_IP}:9696"
  }
  [[ "$DEPLOY_APPS" == "y" ]] && {
    echo "  Calibre         https://${LAN_IP}:8185 (desktop UI — accept self-signed cert)"
    echo "  FileBrowser     http://${LAN_IP}:8081"
    if [[ -n "$FB_TEMP_PW" ]]; then
      echo "                  user: admin  |  temp password: ${FB_TEMP_PW}"
      echo "                  (change at Settings → User Management on first login)"
    fi
  }
  [[ "$DEPLOY_HOME" == "y" ]] && {
    echo "  Home Assistant  http://${LAN_IP}:8123"
  }
  echo ""
  echo "Still to do:"
  echo ""
  echo "1. AdGuard Home — open http://${LAN_IP}:3030 to run the initial setup"
  echo "   wizard. Accept the default Admin Web Interface port (80) when prompted."
  echo "   After the wizard completes, AdGuard is reachable at http://${LAN_IP}:3002."
  echo "   Optional: point your router's DHCP DNS field at ${LAN_IP} for LAN-wide"
  echo "   ad blocking."
  echo ""
  echo "2. Forgejo Actions runner — once Forgejo is up at http://${LAN_IP}:3000:"
  echo "   Site Administration → Actions → Runners → create a runner token, then"
  echo "   install and register the runner on this host."
  echo ""
fi
if [[ "$DEPLOY_MEDIA" == "y" && "$HAS_DOMAIN" == "y" && -n "$QBT_TEMP_PW" ]]; then
  echo "qBittorrent first-login — log in at https://qbittorrent.${HOMELAB_DOMAIN}"
  echo "(or http://${LAN_IP}:8080) with user 'admin' and the one-time temporary"
  echo "password printed by the container on first boot:"
  echo "   ${QBT_TEMP_PW}"
  echo "This rotates on every container restart, so set a permanent one at"
  echo "Tools → Options → Web UI before restarting media."
  echo ""
fi
if [[ "$DEPLOY_APPS" == "y" && "$HAS_DOMAIN" == "y" && -n "$FB_TEMP_PW" ]]; then
  echo "FileBrowser first-login — log in at https://filebrowser.${HOMELAB_DOMAIN}"
  echo "(or http://${LAN_IP}:8081) with user 'admin' and the random initial"
  echo "password generated on first boot:"
  echo "   ${FB_TEMP_PW}"
  echo "Change it at Settings → User Management → admin → Edit."
  echo ""
fi
if [[ "$DEPLOY_OBSERVABILITY" == "y" ]]; then
  echo "Homepage widgets — /opt/homelab/secrets/observability/homepage.env is seeded"
  echo "with 'replace_me' placeholders. Fill in real API keys (AdGuard, Portainer,"
  echo "Plex, etc.) and run:"
  echo "   REPO_ROOT=$REPO_ROOT $REPO_ROOT/infra/scripts/deploy-stack.sh observability"
  echo ""
fi
if [[ "$DEPLOY_HOME" == "y" && -z "$ZIGBEE_DEVICE" ]]; then
  echo "Zigbee device — update the 'devices:' entry in:"
  echo "   $REPO_ROOT/infra/docker/compose/home/docker-compose.yml"
  echo "   Then redeploy: REPO_ROOT=$REPO_ROOT $REPO_ROOT/infra/scripts/deploy-stack.sh home"
  echo ""
fi
if [[ "$DOCKER_NEWLY_INSTALLED" == "y" ]]; then
  echo "Note: Docker was installed during this run. Log out and back in to make"
  echo "the docker group membership permanent (no sudo needed for docker commands)."
  echo ""
fi
