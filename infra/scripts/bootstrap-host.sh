#!/usr/bin/env bash
set -euo pipefail

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: Required file missing: $path" >&2
    exit 1
  fi
}

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
require_dir /opt/homelab/secrets/core
require_dir /opt/homelab/data
require_dir /opt/homelab/data/caddy
require_dir /opt/homelab/data/caddy/data
require_dir /opt/homelab/data/caddy/config
require_dir /opt/homelab/data/forgejo
require_dir /opt/homelab/secrets/observability
require_dir /opt/homelab/secrets/apps
require_dir /opt/homelab/data/homepage

require_file /opt/homelab/secrets/core/caddy.env
require_file /opt/homelab/secrets/core/forgejo.env
require_file /opt/homelab/secrets/observability/grafana.env
require_file /opt/homelab/secrets/apps/firefly.env
require_file /opt/homelab/secrets/apps/firefly-db.env
require_file /opt/homelab/secrets/apps/firefly-importer.env

echo "Bootstrap checks passed."