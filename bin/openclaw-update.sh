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

# Patch existing compose files to fix OOM issues (same as openclaw-onboard)
python3 -c "
import re, sys
text = open(sys.argv[1]).read()
if '--max-old-space-size' not in text:
    text = text.replace('\"node\",\n        \"dist/index.js\"', '\"node\",\n        \"--max-old-space-size=384\",\n        \"dist/index.js\"')
if 'deploy:' in text:
    text = re.sub(r'\n    deploy:\n      resources:\n        limits:\n          memory:\s*\S+\n', '\n    mem_limit: 512m\n', text)
if 'mem_limit' not in text:
    text = text.replace('\n    init: true\n', '\n    init: true\n    mem_limit: 512m\n')
if 'NODE_OPTIONS' not in text:
    text = text.replace('      PATH:', '      NODE_OPTIONS: \"--max-old-space-size=384\"\n      PATH:')
text = re.sub(
    r'healthcheck:.*?start_period:\s*\S+',
    '''healthcheck:
      test: [\"CMD-SHELL\", \"curl -sf --max-time 5 http://127.0.0.1:18789/healthz || wget -qO- --timeout=5 http://127.0.0.1:18789/healthz\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 45s''',
    text, flags=re.DOTALL)
open(sys.argv[1], 'w').write(text)
" "$COMPOSE_FILE" 2>/dev/null || true

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
