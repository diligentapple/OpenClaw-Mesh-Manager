#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-onboard N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
COMPOSE_FILE="${INSTANCE_DIR}/docker-compose.yml"

COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

[[ -f "$COMPOSE_FILE" ]] || { echo "Instance #$N not found. Run openclaw-new $N first."; exit 1; }

echo "Running onboarding for instance #$N..."
$COMPOSE_BIN -f "$COMPOSE_FILE" --profile cli run --rm openclaw-cli onboard
