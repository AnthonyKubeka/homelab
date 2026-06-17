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

echo "Bootstrap checks passed."
