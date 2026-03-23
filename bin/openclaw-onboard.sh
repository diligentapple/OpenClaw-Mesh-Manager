#!/usr/bin/env bash
set -euo pipefail

# Source shared helpers (docker permission wrapper, compose detection)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh" 2>/dev/null \
  || source "/usr/local/lib/openclaw-manager/common.sh"

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

# Stop ALL gateway containers to free memory for the onboarding wizard.
# OpenClaw needs ~500MB heap just to start. On small servers (2-4GB),
# running other gateways alongside the onboard container OOMs the host.
# They'll be restarted after onboarding if they were running.
echo "Stopping gateway containers to free memory for onboarding..."
STOPPED_GATEWAYS=()
for cname in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^openclaw[0-9]+-gateway$' || true); do
  docker stop "$cname" >/dev/null 2>&1 || true
  STOPPED_GATEWAYS+=("$cname")
done

# Run onboarding in a *separate* one-off container that shares the data volume.
# This avoids the gateway's file-watcher restarting the container mid-wizard and
# killing the interactive exec session (the root cause of the "exits after
# channel selection" bug).
docker run --rm -it \
  --init \
  --memory 2g \
  -e HOME=/home/node \
  -e TERM=xterm-256color \
  -e NPM_CONFIG_PREFIX=/home/node/.npm-global \
  -e "NODE_OPTIONS=--max-old-space-size=1536" \
  -e PATH=/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --no-healthcheck \
  -v "${DATA_DIR}:/home/node/.openclaw" \
  "$IMAGE" \
  node dist/index.js onboard --mode local

# Restart the gateway so it picks up the new config written by the wizard.
# IMPORTANT: use docker compose up (not docker restart) so .env is re-read.
echo "Restarting gateway to apply new configuration..."
COMPOSE_FILE="${HOME_DIR}/openclaw${N}/docker-compose.yml"
detect_compose_bin

# Patch existing compose files to fix OOM issues:
#  1. Add/update --max-old-space-size=1536 in node command (entrypoint can override NODE_OPTIONS env)
#  2. Replace deploy.resources (swarm-only) with mem_limit (works standalone)
#  3. Replace node-based healthcheck with lightweight curl/wget
if [[ -f "$COMPOSE_FILE" ]]; then
  python3 - "$COMPOSE_FILE" <<'PYEOF' || true
import re, sys
text = open(sys.argv[1]).read()
# 1. Add or update --max-old-space-size in node command
if '--max-old-space-size' not in text:
    text = text.replace('"node",\n        "dist/index.js"', '"node",\n        "--max-old-space-size=1536",\n        "dist/index.js"')
else:
    text = re.sub(r'--max-old-space-size=\d+', '--max-old-space-size=1536', text)
# 2. Replace deploy.resources block with mem_limit
if 'deploy:' in text:
    text = re.sub(r'\n    deploy:\n      resources:\n        limits:\n          memory:\s*\S+\n', '\n    mem_limit: 2g\n', text)
# Update existing mem_limit or add it
if 'mem_limit' in text:
    text = re.sub(r'mem_limit:\s*\S+', 'mem_limit: 2g', text)
else:
    text = text.replace('\n    init: true\n', '\n    init: true\n    mem_limit: 2g\n')
# 3. Add or update NODE_OPTIONS env
if 'NODE_OPTIONS' not in text:
    text = text.replace('      PATH:', '      NODE_OPTIONS: "--max-old-space-size=1536"\n      PATH:')
else:
    text = re.sub(r'NODE_OPTIONS:.*', 'NODE_OPTIONS: "--max-old-space-size=1536"', text)
# 4. Replace node-based healthcheck with curl/wget
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
    ' node --max-old-space-size=1536 dist/index.js gateway'
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
fi

# Remove stale lock/pid files from data dir before starting
rm -f "${DATA_DIR}"/*.lock "${DATA_DIR}"/*.pid 2>/dev/null || true

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

# Enable insecure auth and host-header origin fallback so the gateway
# can run with BIND=lan (required for mesh networking) without needing
# explicit allowedOrigins.
enable_lan_gateway_config "$DATA_DIR"

# Switch gateway binding to lan now that the config has the required
# origin settings.  This allows the mesh bridge to reach the gateway.
COMPOSE_FILE_DIR="${HOME_DIR}/openclaw${N}"
ENV_FILE="${COMPOSE_FILE_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  sed -i 's/^OPENCLAW_GATEWAY_BIND=.*/OPENCLAW_GATEWAY_BIND=lan/' "$ENV_FILE"
fi

# Restart the gateway to pick up the BIND=lan change
if [[ -f "$COMPOSE_FILE" ]]; then
  $COMPOSE_BIN --project-directory "${COMPOSE_FILE_DIR}" \
    -f "$COMPOSE_FILE" up -d --force-recreate >/dev/null 2>&1 || true
fi

# Restart any other gateways that were stopped to free memory
for cname in "${STOPPED_GATEWAYS[@]+"${STOPPED_GATEWAYS[@]}"}"; do
  [[ "$cname" == "$CONTAINER" ]] && continue  # already recreated above
  echo "Restarting $cname..."
  docker start "$cname" >/dev/null 2>&1 || true
done

# Start or refresh the mesh bridge now that this instance is onboarded
# and the gateway is running. This is where mesh setup belongs — not during
# openclaw-new — because the bridge needs gateways that are fully configured.
MESH_NETWORK=""
NET_FILE="${DATA_DIR}/.mesh-network"
if [[ -f "$NET_FILE" ]]; then
  MESH_NETWORK=$(head -1 "$NET_FILE" 2>/dev/null | tr -d '[:space:]')
fi

if [[ -n "$MESH_NETWORK" ]]; then
  MESH_CMD="$(command -v openclaw-mesh 2>/dev/null || echo "/usr/local/bin/openclaw-mesh")"
  if [[ -x "$MESH_CMD" ]]; then
    local_bridge="openclaw-bridge"
    [[ "$MESH_NETWORK" == "openclaw-net" ]] || local_bridge="openclaw-bridge-${MESH_NETWORK}"
    mesh_args=()
    [[ "$MESH_NETWORK" == "openclaw-net" ]] || mesh_args+=("$MESH_NETWORK")
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$local_bridge"; then
      echo "Refreshing mesh bridge ($MESH_NETWORK)..."
      "$MESH_CMD" refresh "${mesh_args[@]+"${mesh_args[@]}"}"
    else
      echo "Starting mesh bridge ($MESH_NETWORK)..."
      "$MESH_CMD" start "${mesh_args[@]+"${mesh_args[@]}"}"
    fi
  fi
fi
