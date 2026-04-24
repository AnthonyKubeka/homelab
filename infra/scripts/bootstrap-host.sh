#!/usr/bin/env bash
set -euo pipefail

require_dir() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    echo "Creating directory: $path"
    sudo mkdir -p "$path"
  fi
}

echo "Bootstrapping homelab host..."

require_dir /opt/homelab
require_dir /opt/homelab/secrets
require_dir /opt/homelab/data

# Secrets
require_dir /opt/homelab/secrets/core
require_dir /opt/homelab/secrets/observability

# Core
require_dir /opt/homelab/data/caddy/data
require_dir /opt/homelab/data/caddy/config
require_dir /opt/homelab/data/adguard/work
require_dir /opt/homelab/data/adguard/conf
require_dir /opt/homelab/data/forgejo

# Observability
require_dir /opt/homelab/data/homepage

# Apps
require_dir /opt/homelab/data/calibre/config
require_dir /opt/homelab/data/filebrowser/config
require_dir /opt/homelab/data/filebrowser/db

# Media
require_dir /opt/homelab/data/plex/config
require_dir /opt/homelab/data/plex/transcode
require_dir /opt/homelab/data/qbittorrent/config
require_dir /opt/homelab/data/radarr/config
require_dir /opt/homelab/data/sonarr/config
require_dir /opt/homelab/data/prowlarr/config

# Home
require_dir /opt/homelab/data/homeassistant/config
require_dir /opt/homelab/data/homeassistant/matter-server

echo "Bootstrap checks passed."
