#!/usr/bin/env bash
set -euo pipefail

# Source shared helpers (docker permission wrapper, compose detection)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh" 2>/dev/null \
  || source "/usr/local/lib/openclaw-manager/common.sh"

usage() { echo "Usage: openclaw-update N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
COMPOSE_FILE="${INSTANCE_DIR}/docker-compose.yml"
CONTAINER="openclaw${N}-gateway"

detect_compose_bin

[[ -f "$COMPOSE_FILE" ]] || { echo "Missing: $COMPOSE_FILE"; exit 1; }

# 1. Backup config before updating
CONFIG="${DATA_DIR}/openclaw.json"
if sudo test -f "$CONFIG" 2>/dev/null; then
  backup="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  sudo cp "$CONFIG" "$backup"
  echo "Config backed up to $backup"
fi

# Ensure NODE_OPTIONS and memory limit are sufficient.  Older compose files
# may have lower values or be missing NODE_OPTIONS entirely.
if ! grep -q 'NODE_OPTIONS' "$COMPOSE_FILE"; then
  sed -i '/^      PATH:/a\      NODE_OPTIONS: "--max-old-space-size=768"' "$COMPOSE_FILE"
else
  sed -i 's/--max-old-space-size=[0-9]*/--max-old-space-size=768/' "$COMPOSE_FILE"
fi
sed -i 's/memory: 512M/memory: 1024M/' "$COMPOSE_FILE"

# 2. Pull latest image
echo "Pulling latest OpenClaw image..."
docker pull ghcr.io/openclaw/openclaw:latest

# 3. Recreate container with new image
$COMPOSE_BIN -f "$COMPOSE_FILE" up -d --force-recreate

# 4. Wait for container to be ready
echo "Waiting for container to start..."
local_tries=0
while ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" && [[ $local_tries -lt 15 ]]; do
  sleep 1
  ((local_tries++)) || true
done

# 5. Run doctor to handle config migrations
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Running config migration (doctor)..."
  docker exec "$CONTAINER" node /app/dist/index.js doctor 2>/dev/null || true

  # 6. Restart gateway to pick up migrated config
  echo "Restarting gateway..."
  docker restart "$CONTAINER" >/dev/null 2>&1

  # 7. Verify health
  sleep 3
  API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
  if [[ -n "$API_PORT" ]] && curl -sf "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1; then
    echo "Instance #$N updated and healthy."
  else
    echo "Instance #$N updated but health check failed."
    echo "  Check logs: openclaw-logs $N --tail 20"
  fi
else
  echo "Warning: container did not start. Check: openclaw-logs $N"
fi
