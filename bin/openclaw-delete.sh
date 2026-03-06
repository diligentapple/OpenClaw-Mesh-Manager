#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: openclaw-delete N"
  echo "Example: openclaw-delete 3"
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

N="${1:-}"
if ! is_int "$N"; then usage; exit 1; fi

HOME_DIR="${HOME:-/root}"
INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
CONTAINER="openclaw${N}-gateway"

COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

echo "About to DELETE OpenClaw instance #$N"
echo "This will remove:"
echo " - container(s) for instance #$N"
echo " - ${INSTANCE_DIR}"
echo " - ${DATA_DIR}"
echo ""
read -r -p "Type DELETE to confirm: " CONFIRM
if [[ "$CONFIRM" != "DELETE" ]]; then
  echo "Aborted."
  exit 1
fi

# Prefer compose down if compose file exists
if [[ -f "${INSTANCE_DIR}/docker-compose.yml" ]]; then
  $COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" down -v || true
else
  # fallback
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
fi

# Data dir may contain files owned by UID 1000 (container's node user).
# Use a disposable container to clean up files we can't remove as host user.
if [[ -d "$DATA_DIR" ]]; then
  docker run --rm -v "${DATA_DIR}:/cleanup" busybox rm -rf /cleanup || \
    rm -rf "${DATA_DIR}"
fi
rm -rf "${INSTANCE_DIR}"

echo "Deleted instance #$N"
