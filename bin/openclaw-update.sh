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

resolve_gateway_runtime_memory_settings OPENCLAW_GATEWAY_MEMORY_LIMIT OPENCLAW_GATEWAY_NODE_HEAP_MB
ENV_FILE="${INSTANCE_DIR}/.env"
upsert_env_var "$ENV_FILE" "OPENCLAW_GATEWAY_MEMORY_LIMIT" "${OPENCLAW_GATEWAY_MEMORY_LIMIT}"
upsert_env_var "$ENV_FILE" "OPENCLAW_GATEWAY_NODE_HEAP_MB" "${OPENCLAW_GATEWAY_NODE_HEAP_MB}"

# Patch existing compose files to fix OOM issues (same as openclaw-onboard)
python3 - "$COMPOSE_FILE" <<'PYEOF' || true
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r'--max-old-space-size=\d+', '--max-old-space-size=${OPENCLAW_GATEWAY_NODE_HEAP_MB:-3072}', text)
if 'deploy:' in text:
    text = re.sub(r'\n    deploy:\n      resources:\n        limits:\n          memory:\s*\S+\n', '\n    mem_limit: ${OPENCLAW_GATEWAY_MEMORY_LIMIT:-4g}\n', text)
if 'mem_limit' in text:
    text = re.sub(r'mem_limit:\s*\S+', 'mem_limit: ${OPENCLAW_GATEWAY_MEMORY_LIMIT:-4g}', text)
else:
    text = text.replace('\n    init: true\n', '\n    init: true\n    mem_limit: ${OPENCLAW_GATEWAY_MEMORY_LIMIT:-4g}\n')
if 'NODE_OPTIONS' not in text:
    text = text.replace('      PATH:', '      NODE_OPTIONS: "--max-old-space-size=${OPENCLAW_GATEWAY_NODE_HEAP_MB:-3072}"\n      PATH:')
else:
    text = re.sub(r'NODE_OPTIONS:.*', 'NODE_OPTIONS: "--max-old-space-size=${OPENCLAW_GATEWAY_NODE_HEAP_MB:-3072}"', text)
text = re.sub(
    r'healthcheck:.*?start_period:\s*\S+',
    'healthcheck:\n'
    '      test: ["CMD-SHELL", "curl -sf --max-time 5 http://127.0.0.1:18789/healthz || wget -qO- --timeout=5 http://127.0.0.1:18789/healthz"]\n'
    '      interval: 30s\n'
    '      timeout: 10s\n'
    '      retries: 3\n'
    '      start_period: 45s',
    text, flags=re.DOTALL)

ENTRYPOINT_BLOCK = (
    'entrypoint:\n'
    '      [\n'
    '        "/bin/sh",\n'
    '        "-c",\n'
    '        "rm -f /home/node/.openclaw/*.lock /home/node/.openclaw/*.pid 2>/dev/null;'
    ' START=$$(date +%s);'
    ' node --max-old-space-size=${OPENCLAW_GATEWAY_NODE_HEAP_MB:-3072} dist/index.js gateway'
    ' --bind ${OPENCLAW_GATEWAY_BIND:-loopback} --port 18789 --allow-unconfigured;'
    ' EXIT=$$?; ELAPSED=$$(($$(date +%s) - START));'
    ' if [ $$ELAPSED -lt 10 ]; then'
    " echo '[openclaw] Exited after '$$ELAPSED's (code '$$EXIT'). Waiting 30s...'; sleep 30;"
    ' fi; exit $$EXIT"\n'
    '      ]'
)

# 5. Convert command: to entrypoint: with stale lock cleanup and crash guard
text = re.sub(r'command:\s*\[.*?\]', ENTRYPOINT_BLOCK, text, flags=re.DOTALL)
# 6. Upgrade existing entrypoint: blocks that lack the crash guard
if 'entrypoint:' in text and 'restart storm' not in text and 'Waiting 30s' not in text:
    text = re.sub(r'entrypoint:\s*\[.*?\]', ENTRYPOINT_BLOCK, text, flags=re.DOTALL)
# 7. Upgrade restart policy: on-failure:5 -> unless-stopped (crash guard prevents storms)
text = re.sub(r'restart:\s*"on-failure:\d+"', 'restart: unless-stopped', text)
open(sys.argv[1], 'w').write(text)
PYEOF

# Stop ALL other gateway containers to free memory.
# OpenClaw needs ~760MB heap; running doctor via docker exec spawns a second
# node process inside the container, so even one gateway + doctor = ~1.5GB.
# With other gateways running too, the host OOMs.
echo "Stopping other gateways to free memory..."
STOPPED_GATEWAYS=()
for cname in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^openclaw[0-9]+-gateway$' || true); do
  [[ "$cname" == "$CONTAINER" ]] && continue
  docker stop "$cname" >/dev/null 2>&1 || true
  STOPPED_GATEWAYS+=("$cname")
done

resolve_container_memory_settings OPENCLAW_UPDATE_MEMORY_LIMIT OPENCLAW_UPDATE_NODE_HEAP_MB
echo "Doctor container memory limit: ${OPENCLAW_UPDATE_MEMORY_LIMIT} (Node heap: ${OPENCLAW_UPDATE_NODE_HEAP_MB} MB)"

echo "Gateway runtime memory limit: ${OPENCLAW_GATEWAY_MEMORY_LIMIT} (Node heap: ${OPENCLAW_GATEWAY_NODE_HEAP_MB} MB)"

# Remove stale lock/pid files from data dir before starting
rm -f "${DATA_DIR}"/*.lock "${DATA_DIR}"/*.pid 2>/dev/null || true

# 2. Pull latest image
echo "Pulling latest OpenClaw image..."
docker pull ghcr.io/openclaw/openclaw:latest

# 3. Run doctor in a one-off container (NOT docker exec) to avoid running
#    two node processes simultaneously inside the gateway container.
echo "Running config migration (doctor)..."
docker run --rm \
  --init \
  --memory "${OPENCLAW_UPDATE_MEMORY_LIMIT}" \
  --no-healthcheck \
  -e HOME=/home/node \
  -e "NODE_OPTIONS=--max-old-space-size=${OPENCLAW_UPDATE_NODE_HEAP_MB}" \
  -v "${DATA_DIR}:/home/node/.openclaw" \
  ghcr.io/openclaw/openclaw:latest \
  node dist/index.js doctor 2>/dev/null || true

# 4. Start the updated container
$COMPOSE_BIN -f "$COMPOSE_FILE" up -d --force-recreate

# 5. Wait for container to be ready and verify health
echo "Waiting for container to start..."
local_tries=0
while ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" && [[ $local_tries -lt 15 ]]; do
  sleep 1
  ((local_tries++)) || true
done

sleep 3
API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
if [[ -n "$API_PORT" ]] && curl -sf "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1; then
  echo "Instance #$N updated and healthy."
else
  echo "Instance #$N updated but health check failed."
  echo "  Check logs: openclaw-logs $N --tail 20"
fi

# 6. Restart other gateways that were stopped
for cname in "${STOPPED_GATEWAYS[@]+"${STOPPED_GATEWAYS[@]}"}"; do
  echo "Restarting $cname..."
  docker start "$cname" >/dev/null 2>&1 || true
done
