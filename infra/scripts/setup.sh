#!/usr/bin/env bash
set -euo pipefail

# Run this once on a fresh host before your first deploy.
# Creates the base directory structure and copies example secrets into place.
# Per-stack directories are created automatically when each stack is deployed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "Homelab setup"
echo "Repo root: $REPO_ROOT"
echo ""

echo "Creating base directories..."
sudo mkdir -p \
  /opt/homelab/secrets/core \
  /opt/homelab/secrets/observability \
  /opt/homelab/data \
  /opt/homelab/caddy

sudo chown -R "$USER:$USER" /opt/homelab
echo "Done."
echo ""

echo "Copying secrets examples..."
copy_secret() {
  local src="$1"
  local dst="$2"
  if [[ -f "$dst" ]]; then
    echo "  skipping $dst (already exists)"
  else
    cp "$src" "$dst"
    echo "  created $dst"
  fi
}

copy_secret "$REPO_ROOT/infra/secrets/examples/core/caddy.env.exampe"             /opt/homelab/secrets/core/caddy.env
copy_secret "$REPO_ROOT/infra/secrets/examples/core/forgejo.env.example"           /opt/homelab/secrets/core/forgejo.env
copy_secret "$REPO_ROOT/infra/secrets/examples/observability/grafana.env.example"  /opt/homelab/secrets/observability/grafana.env

echo ""
echo "Setup complete. Next steps:"
echo ""
echo "1. Fill in your secrets:"
echo "   /opt/homelab/secrets/core/caddy.env           — Porkbun API keys + HOMELAB_DOMAIN"
echo "   /opt/homelab/secrets/core/forgejo.env          — Forgejo domain config"
echo "   /opt/homelab/secrets/observability/grafana.env — Grafana admin password (if using observability)"
echo ""
echo "2. Build the custom Caddy binary into /opt/homelab/caddy/"
echo "   See README for instructions."
echo ""
echo "3. Trim the Caddyfile to only include subdomains for stacks you plan to deploy:"
echo "   $REPO_ROOT/infra/docker/config/caddy/Caddyfile"
echo ""
echo "4. Deploy:"
echo "   REPO_ROOT=$REPO_ROOT $REPO_ROOT/infra/scripts/deploy-stack.sh core"
