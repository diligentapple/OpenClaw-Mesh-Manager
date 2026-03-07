#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-update N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
COMPOSE_FILE="${INSTANCE_DIR}/docker-compose.yml"

COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

[[ -f "$COMPOSE_FILE" ]] || { echo "Missing: $COMPOSE_FILE"; exit 1; }

docker pull ghcr.io/phioranex/openclaw-docker:latest
$COMPOSE_BIN -f "$COMPOSE_FILE" up -d --force-recreate
echo "Updated instance #$N"
