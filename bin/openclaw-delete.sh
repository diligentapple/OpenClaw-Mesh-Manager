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

if [[ ! -d "$INSTANCE_DIR" && ! -d "$DATA_DIR" ]]; then
  echo "Instance #$N does not exist."
  exit 1
fi

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

# Clean up tailscale serve if active for this instance's port (before stopping container)
if command -v tailscale >/dev/null 2>&1; then
  API_PORT=$(docker port "${CONTAINER}" 18789/tcp 2>/dev/null | head -1 | cut -d: -f2 || echo "")
  if [[ -n "${API_PORT:-}" ]]; then
    ts_serve_status=$(sudo tailscale serve status 2>/dev/null || echo "")
    if echo "$ts_serve_status" | grep -q ":${API_PORT}"; then
      echo "Stopping Tailscale Serve for port $API_PORT..."
      sudo tailscale serve --https=443 off 2>/dev/null || true
    fi
  fi
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
  docker run --rm --user root --entrypoint sh -v "${DATA_DIR}:/cleanup" ghcr.io/phioranex/openclaw-docker:latest -c 'rm -rf /cleanup/*'
fi
rm -rf "${DATA_DIR}" "${INSTANCE_DIR}"

# Remove shortcut symlink if it exists
SHORTCUT="/usr/local/bin/openclaw${N}"
if [[ -L "$SHORTCUT" ]]; then
  rm -f "$SHORTCUT"
fi

echo "Deleted instance #$N"
