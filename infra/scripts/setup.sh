#!/usr/bin/env bash
set -euo pipefail

# Run this once on a fresh host before your first deploy.
# It creates required directories and copies example secrets files.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "Homelab setup"
echo "Repo root: $REPO_ROOT"
echo ""

# Create directory structure
echo "Creating directories..."
sudo mkdir -p \
  /opt/homelab/secrets/core \
  /opt/homelab/secrets/observability \
  /opt/homelab/data/caddy/data \
  /opt/homelab/data/caddy/config \
  /opt/homelab/data/adguard/work \
  /opt/homelab/data/adguard/conf \
  /opt/homelab/data/forgejo \
  /opt/homelab/data/homepage \
  /opt/homelab/data/calibre/config \
  /opt/homelab/data/filebrowser/config \
  /opt/homelab/data/filebrowser/db \
  /opt/homelab/data/plex/config \
  /opt/homelab/data/plex/transcode \
  /opt/homelab/data/qbittorrent/config \
  /opt/homelab/data/radarr/config \
  /opt/homelab/data/sonarr/config \
  /opt/homelab/data/prowlarr/config \
  /opt/homelab/data/homeassistant/config \
  /opt/homelab/data/homeassistant/matter-server \
  /opt/homelab/caddy

sudo chown -R "$USER:$USER" /opt/homelab
echo "Directories created."
echo ""

# Copy secrets examples
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
echo "Setup complete. Fill in your secrets before deploying:"
echo ""
echo "  /opt/homelab/secrets/core/caddy.env           — Porkbun API keys + HOMELAB_DOMAIN"
echo "  /opt/homelab/secrets/core/forgejo.env          — Forgejo config"
echo "  /opt/homelab/secrets/observability/grafana.env — Grafana admin password"
echo ""
echo "Also configure your media mount points in:"
echo "  infra/docker/compose/media/docker-compose.yml  — /mnt/media, /mnt/torrents"
echo "  infra/docker/compose/apps/docker-compose.yml   — /mnt/media/books"
echo ""
echo "And build your custom Caddy binary (with caddy-dns/porkbun) at /opt/homelab/caddy/"
echo "See: https://caddyserver.com/docs/build#xcaddy"
