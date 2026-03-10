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

# Verify the container exists (running, restarting, or any state)
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Error: container '$CONTAINER' does not exist."
  echo "Use 'openclaw-new $N' to create it, or 'openclaw-list' to see instances."
  exit 1
fi

# Resolve the image the instance is running so the onboarding container matches
IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo "ghcr.io/openclaw/openclaw:latest")

echo "Running onboarding for instance #$N..."

# Run onboarding in a *separate* one-off container that shares the data volume.
# This avoids the gateway's file-watcher restarting the container mid-wizard and
# killing the interactive exec session (the root cause of the "exits after
# channel selection" bug).
docker run --rm -it \
  -e HOME=/home/node \
  -e TERM=xterm-256color \
  -e NPM_CONFIG_PREFIX=/home/node/.npm-global \
  -e PATH=/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -v "${DATA_DIR}:/home/node/.openclaw" \
  "$IMAGE" \
  node dist/index.js onboard --mode local

# Restart the gateway so it picks up the new config written by the wizard
echo "Restarting gateway to apply new configuration..."
docker restart "$CONTAINER" >/dev/null 2>&1 || true

# Wait briefly for the container to come back up
for _ in $(seq 1 15); do
  sleep 1
  s=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
  [[ "$s" == "running" ]] && break
done

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
