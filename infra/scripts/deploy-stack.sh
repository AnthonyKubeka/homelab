#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <stack-name>"
  exit 1
fi

STACK_NAME="$1"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STACK_DIR="$REPO_ROOT/infra/docker/compose/$STACK_NAME"

if [[ ! -d "$STACK_DIR" ]]; then
  echo "ERROR: Stack directory not found: $STACK_DIR"
  exit 1
fi

export REPO_ROOT

echo "Deploying stack: $STACK_NAME"
echo "Repo root: $REPO_ROOT"

bash "$REPO_ROOT/infra/scripts/bootstrap-host.sh"

require_secret() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: Required secret missing: $path" >&2
    exit 1
  fi
}

case "$STACK_NAME" in
  core)
    require_secret /opt/homelab/secrets/core/caddy.env
    require_secret /opt/homelab/secrets/core/forgejo.env
    ;;
  observability)
    require_secret /opt/homelab/secrets/observability/grafana.env
    ;;
  apps)
    ;;
esac

cd "$STACK_DIR"

echo "Rendering compose config..."
docker compose config >/dev/null

if [[ "$STACK_NAME" == "core" ]]; then
  echo "Updating core stack..."
  docker compose up -d --force-recreate caddy
  docker compose up -d
else
  echo "Pulling latest images..."
  docker compose pull

  echo "Starting stack..."
  docker compose up -d --remove-orphans
fi

if [[ "$STACK_NAME" == "core" ]]; then
  if docker ps --format '{{.Names}}' | grep -qx caddy; then
    echo "Validating Caddy config..."
    docker exec caddy caddy validate --config /etc/caddy/Caddyfile

    echo "Reloading Caddy..."
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile
  else
    echo "WARNING: caddy container not running; skipping reload"
  fi
fi

echo "Stack deployed: $STACK_NAME"
