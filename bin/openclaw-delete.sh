#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: openclaw-delete N|N-M"
  echo "Example: openclaw-delete 3"
  echo "         openclaw-delete 2-4    (delete instances 2, 3, 4)"
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

RANGE_ARG="${1:-}"

# Parse N or N-M range
if [[ "$RANGE_ARG" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  RANGE_START="${BASH_REMATCH[1]}"
  RANGE_END="${BASH_REMATCH[2]}"
  if [[ "$RANGE_START" -lt 1 || "$RANGE_END" -lt "$RANGE_START" ]]; then
    echo "Error: invalid range $RANGE_ARG (start must be >= 1 and <= end)"
    exit 1
  fi
elif is_int "$RANGE_ARG" && [[ "$RANGE_ARG" -ge 1 ]]; then
  RANGE_START="$RANGE_ARG"
  RANGE_END="$RANGE_ARG"
else
  usage; exit 1
fi

HOME_DIR="${HOME:-/root}"

COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

# Collect instances that actually exist
TARGETS=()
for (( i=RANGE_START; i<=RANGE_END; i++ )); do
  idir="${HOME_DIR}/openclaw${i}"
  ddir="${HOME_DIR}/.openclaw${i}"
  if [[ -d "$idir" || -d "$ddir" ]]; then
    TARGETS+=("$i")
  fi
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No instances found in range ${RANGE_START}-${RANGE_END}."
  exit 1
fi

# Show what will be deleted
echo "About to DELETE the following OpenClaw instances:"
for n in "${TARGETS[@]}"; do
  echo "  #$n  (openclaw${n}/ .openclaw${n}/)"
done
echo ""
read -r -p "Type DELETE to confirm: " CONFIRM
if [[ "$CONFIRM" != "DELETE" ]]; then
  echo "Aborted."
  exit 1
fi

# ---------------------------------------------------------------------------
# Delete each instance
# ---------------------------------------------------------------------------

delete_instance() {
  local N="$1"
  local INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
  local DATA_DIR="${HOME_DIR}/.openclaw${N}"
  local CONTAINER="openclaw${N}-gateway"

  # Clean up tailscale serve for this instance's API port
  if command -v tailscale >/dev/null 2>&1; then
    API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || echo "")
    if [[ -z "${API_PORT:-}" ]]; then
      API_PORT=$(grep -oP '"\K[0-9]+(?=:18789")' "${INSTANCE_DIR}/docker-compose.yml" 2>/dev/null || echo "")
    fi
    if [[ -n "${API_PORT:-}" ]]; then
      sudo tailscale serve --https="$API_PORT" off 2>/dev/null || true
    fi
  fi

  # Prefer compose down if compose file exists
  if [[ -f "${INSTANCE_DIR}/docker-compose.yml" ]]; then
    $COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" down -v || true
  else
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  fi

  # Data dir may contain files owned by UID 1000 (container's node user).
  # Try docker first (handles uid 1000 files), fall back to sudo rm.
  if [[ -d "$DATA_DIR" ]]; then
    docker run --rm --user root --entrypoint sh -v "${DATA_DIR}:/cleanup" ghcr.io/openclaw/openclaw:latest -c 'rm -rf /cleanup/*' 2>/dev/null \
      || sudo rm -rf "${DATA_DIR:?}"/* 2>/dev/null || true
  fi
  rm -rf "${DATA_DIR}" "${INSTANCE_DIR}" 2>/dev/null \
    || sudo rm -rf "${DATA_DIR}" "${INSTANCE_DIR}" 2>/dev/null || true

  # Remove shortcut symlink if it exists
  SHORTCUT="/usr/local/bin/openclaw${N}"
  if [[ -L "$SHORTCUT" ]]; then
    rm -f "$SHORTCUT" 2>/dev/null || sudo rm -f "$SHORTCUT" 2>/dev/null || true
  fi

  echo "Deleted instance #$N"
}

for n in "${TARGETS[@]}"; do
  delete_instance "$n"
done

echo ""
echo "Done: ${#TARGETS[@]} instance(s) deleted."
