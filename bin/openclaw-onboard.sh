#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-onboard N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
CONTAINER="openclaw${N}-gateway"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "Data directory $DATA_DIR not found. Run openclaw-new $N first."
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' is not running."
  echo "Use 'openclaw-list' to see running instances."
  exit 1
fi

echo "Running onboarding for instance #$N..."
docker exec -it "$CONTAINER" node dist/index.js onboard --mode local

# Always enable insecure auth so HTTP fallback URLs work without HTTPS
CONFIG="${DATA_DIR}/openclaw.json"
if [[ -f "$CONFIG" ]]; then
  local_tmp=$(mktemp)
  if sudo jq '.gateway.controlUi.allowInsecureAuth = true' "$CONFIG" > "$local_tmp" && jq empty "$local_tmp" 2>/dev/null; then
    owner=$(sudo stat -c '%u:%g' "$CONFIG")
    sudo mv "$local_tmp" "$CONFIG"
    sudo chown "$owner" "$CONFIG"
  else
    rm -f "$local_tmp"
  fi
fi
