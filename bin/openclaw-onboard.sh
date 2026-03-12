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

# Restart the gateway so it picks up the new config written by the wizard.
# IMPORTANT: use docker compose up (not docker restart) so .env is re-read.
echo "Restarting gateway to apply new configuration..."
COMPOSE_FILE="${HOME_DIR}/openclaw${N}/docker-compose.yml"
COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_BIN="docker-compose"
  fi
fi

if [[ -f "$COMPOSE_FILE" ]]; then
  $COMPOSE_BIN --project-directory "${HOME_DIR}/openclaw${N}" \
    -f "$COMPOSE_FILE" up -d --force-recreate >/dev/null 2>&1 || true
else
  docker restart "$CONTAINER" >/dev/null 2>&1 || true
fi

# Wait for the container to come back up and respond.
# Re-query docker port each iteration because after force-recreate the
# container needs a moment before port mappings are available.
API_PORT=""
for i in $(seq 1 20); do
  sleep 1
  if [[ -z "$API_PORT" ]]; then
    API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
  fi
  if [[ -n "${API_PORT:-}" ]] && curl -sf --max-time 3 "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1; then
    echo "Gateway is up."
    break
  fi
  if [[ "$i" -eq 20 ]]; then
    echo "Warning: gateway not responding after 20s. Check: openclaw-logs $N --tail 20"
  fi
done

# Always enable insecure auth so HTTP fallback URLs work without HTTPS
CONFIG="${DATA_DIR}/openclaw.json"
if sudo test -f "$CONFIG" 2>/dev/null; then
  local_tmp=$(mktemp)
  if sudo jq '.gateway.controlUi.allowInsecureAuth = true' "$CONFIG" > "$local_tmp" && jq empty "$local_tmp" 2>/dev/null; then
    owner=$(sudo stat -c '%u:%g' "$CONFIG")
    sudo mv "$local_tmp" "$CONFIG"
    sudo chown "$owner" "$CONFIG"
  else
    rm -f "$local_tmp"
  fi
fi
