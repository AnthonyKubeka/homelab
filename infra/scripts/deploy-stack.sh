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

if [[ "$STACK_NAME" == "core" ]]; then
  echo "Syncing Caddy config..."
  mkdir -p /home/commander-shepard/caddy
  rsync -av \
    "$REPO_ROOT/infra/docker/config/caddy/" \
    /home/commander-shepard/caddy/
fi

cd "$STACK_DIR"

echo "Rendering compose config..."
docker compose config >/dev/null

if [[ "$STACK_NAME" == "core" ]]; then
  echo "Updating core stack without tearing it down first..."
  docker compose up -d --force-recreate caddy
  docker compose up -d
else
  echo "Pulling latest images..."
  docker compose pull
  
  echo "Stopping existing stack containers..."
  docker compose down --remove-orphans || true

  echo "Starting stack..."
  docker compose up -d
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