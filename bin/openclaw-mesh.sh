#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# openclaw-mesh — Manage the cross-instance mesh network & bridge
# ---------------------------------------------------------------------------

NETWORK_NAME="${OPENCLAW_MESH_NETWORK:-openclaw-net}"
HOME_DIR="${HOME:-/root}"
MESH_BASE_DIR="${HOME_DIR}/.openclaw-mesh"
BRIDGE_CONTAINER="openclaw-bridge"
BRIDGE_INTERNAL_PORT=3000
SHARE_DIR="${OPENCLAW_MGR_SHARE:-/usr/local/share/openclaw-manager}"

# Derived paths (updated after parsing args)
MESH_DIR=""

# Set derived variables based on network name
set_network_vars() {
  if [[ "$NETWORK_NAME" == "openclaw-net" ]]; then
    MESH_DIR="${MESH_BASE_DIR}"
    BRIDGE_CONTAINER="openclaw-bridge"
  else
    MESH_DIR="${MESH_BASE_DIR}/${NETWORK_NAME}"
    BRIDGE_CONTAINER="openclaw-bridge-${NETWORK_NAME}"
  fi
}

usage() {
  cat <<'EOF'
Usage: openclaw-mesh <command> [NETWORK]

Commands:
  start  [NETWORK]   Create mesh network, discover instances, launch bridge
  stop   [NETWORK]   Stop the bridge and (if empty) remove the network
  status [NETWORK]   Show mesh status, connected instances, bridge health
  refresh [NETWORK]  Re-discover instances, regenerate config, restart bridge

NETWORK defaults to "openclaw-net" if omitted.

Named networks let you isolate groups of instances:
  openclaw-mesh start research       # Only instances with --mesh research
  openclaw-mesh start                # Default network (openclaw-net)

Assign instances to a network when creating them:
  openclaw-new 1 --mesh research
  openclaw-new 2 --mesh research
  openclaw-new 3 --mesh ops

Inside a container on the "research" network, the bridge is at:
  curl -s -X POST http://openclaw-bridge-research:3000/send \
    -H 'Content-Type: application/json' \
    -d '{"to": 2, "message": "Hello from instance 1"}'

(For the default network, the bridge is at http://openclaw-bridge:3000)

Bridge endpoints:
  GET  /health      Bridge health check
  GET  /instances   List registered instances
  POST /send        Send message, wait for agent response
  POST /inject      Inject assistant message into a session
  POST /relay       Send to B, inject response into A's session
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

# Return list of "NUM:TOKEN" pairs for instances belonging to this network
collect_instances() {
  local entries=()

  for dir in "${HOME_DIR}"/openclaw[0-9]*/; do
    [[ -d "$dir" ]] || continue
    local base num env_file token inst_network
    base="$(basename "$dir")"
    num="${base#openclaw}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue

    # Check which network this instance belongs to
    local net_file="${HOME_DIR}/.openclaw${num}/.mesh-network"
    if [[ -f "$net_file" ]]; then
      inst_network=$(head -1 "$net_file" 2>/dev/null | tr -d '[:space:]')
    else
      inst_network="openclaw-net"
    fi
    # Skip instances not on this mesh network
    [[ "$inst_network" == "$NETWORK_NAME" ]] || continue

    env_file="${dir}.env"
    token=""

    # Primary: read token from the compose .env file
    if [[ -f "$env_file" ]]; then
      token=$(grep -oP '^OPENCLAW_GATEWAY_TOKEN=\K.*' "$env_file" 2>/dev/null || true)
    fi

    # Fallback: read from the instance config JSON
    if [[ -z "$token" ]]; then
      local cfg="${HOME_DIR}/.openclaw${num}/openclaw.json"
      if [[ -f "$cfg" ]]; then
        token=$(jq -r '.gateway.auth.token // empty' "$cfg" 2>/dev/null || true)
      fi
    fi

    if [[ -n "$token" ]]; then
      entries+=("${num}:${token}")
    else
      echo "  ⚠  Instance #${num}: token not found, skipping" >&2
    fi
  done

  echo "${entries[*]}"
}

# Read instance metadata (name + description) from ~/.openclawN/.mesh-meta
# or fall back to the container name. Returns "name|description".
get_instance_meta() {
  local num="$1"
  local meta_file="${HOME_DIR}/.openclaw${num}/.mesh-meta"
  local name="Instance ${num}"
  local desc=""

  if [[ -f "$meta_file" ]]; then
    name=$(head -1 "$meta_file" 2>/dev/null | tr -d '\n' || echo "Instance ${num}")
    desc=$(sed -n '2p' "$meta_file" 2>/dev/null | tr -d '\n' || true)
  fi

  # Sanitize for JSON (escape double quotes and backslashes)
  name=$(echo "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
  desc=$(echo "$desc" | sed 's/\\/\\\\/g; s/"/\\"/g')

  echo "${name}|${desc}"
}

generate_config() {
  local raw
  raw=$(collect_instances)

  mkdir -p "$MESH_DIR"

  # Build JSON manually (no jq dependency for writing)
  local json='{"instances":{'
  local first=true
  for entry in $raw; do
    local num="${entry%%:*}"
    local token="${entry#*:}"
    local meta name desc
    meta=$(get_instance_meta "$num")
    name="${meta%%|*}"
    desc="${meta#*|}"
    $first || json+=','
    first=false
    json+="\"${num}\":{\"host\":\"openclaw${num}-gateway\",\"port\":18789,\"token\":\"${token}\",\"name\":\"${name}\",\"description\":\"${desc}\"}"
  done
  json+='}}'

  # Pretty-print if possible, otherwise raw
  if command -v python3 >/dev/null 2>&1; then
    echo "$json" | python3 -m json.tool > "${MESH_DIR}/config.json"
  elif command -v jq >/dev/null 2>&1; then
    echo "$json" | jq '.' > "${MESH_DIR}/config.json"
  else
    echo "$json" > "${MESH_DIR}/config.json"
  fi

  echo "Config written to ${MESH_DIR}/config.json"
}

ensure_network() {
  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "Docker network $NETWORK_NAME already exists"
  else
    docker network create "$NETWORK_NAME"
    echo "Created Docker network: $NETWORK_NAME"
  fi
}

# Attach running instances belonging to this network to the mesh Docker network
connect_instances() {
  local connected_list
  connected_list=$(docker network inspect "$NETWORK_NAME" \
    --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)

  for dir in "${HOME_DIR}"/openclaw[0-9]*/; do
    [[ -d "$dir" ]] || continue
    local base num container inst_network
    base="$(basename "$dir")"
    num="${base#openclaw}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue

    # Check which network this instance belongs to
    local net_file="${HOME_DIR}/.openclaw${num}/.mesh-network"
    if [[ -f "$net_file" ]]; then
      inst_network=$(head -1 "$net_file" 2>/dev/null | tr -d '[:space:]')
    else
      inst_network="openclaw-net"
    fi
    [[ "$inst_network" == "$NETWORK_NAME" ]] || continue

    container="openclaw${num}-gateway"

    # Only if the container is running
    if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
      continue
    fi

    if echo "$connected_list" | grep -q "$container"; then
      echo "  $container — already on $NETWORK_NAME"
    else
      docker network connect "$NETWORK_NAME" "$container" 2>/dev/null \
        && echo "  $container — connected to $NETWORK_NAME" \
        || echo "  $container — FAILED to connect"
    fi
  done
}

# Announce the network roster to all connected instances via the bridge
announce_roster() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$BRIDGE_CONTAINER"; then
    return 0
  fi

  echo "Announcing network roster to all instances..."

  # Build a roster text from config.json
  local roster=""
  if command -v jq >/dev/null 2>&1 && [[ -f "${MESH_DIR}/config.json" ]]; then
    roster=$(jq -r --arg net "$NETWORK_NAME" --arg bridge "$BRIDGE_CONTAINER" '
      "[OpenClaw Mesh Network: " + $net + "] Connected instances:\n" +
      ([.instances | to_entries[] |
        "  • Instance " + .key +
        (if .value.name and .value.name != "" then " (" + .value.name + ")" else "" end) +
        (if .value.description and .value.description != "" then " — " + .value.description else "" end)
      ] | join("\n")) +
      "\n\nTo message another instance: curl -s -X POST http://" + $bridge + ":3000/send -H \"Content-Type: application/json\" -d \'{\"to\": N, \"message\": \"...\"}\' " +
      "\nTo see all instances: curl -s http://" + $bridge + ":3000/instances"
    ' "${MESH_DIR}/config.json" 2>/dev/null || true)
  fi

  if [[ -z "$roster" ]]; then
    return 0
  fi

  # Inject the roster into each instance's main session via the bridge API
  local config_instances
  config_instances=$(jq -r '.instances | keys[]' "${MESH_DIR}/config.json" 2>/dev/null || true)
  for inst_id in $config_instances; do
    docker exec "$BRIDGE_CONTAINER" node -e "
      const http = require('http');
      const data = JSON.stringify({
        instance: ${inst_id},
        sessionKey: 'main',
        message: $(printf '%s' "$roster" | jq -Rs .),
        label: 'mesh-roster'
      });
      const req = http.request({
        hostname: '127.0.0.1',
        port: ${BRIDGE_INTERNAL_PORT},
        path: '/inject',
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }
      }, res => {
        let b=''; res.on('data',c=>b+=c);
        res.on('end', () => { console.log('Instance ${inst_id}:', b); });
      });
      req.on('error', e => console.error('Instance ${inst_id}: failed -', e.message));
      req.write(data);
      req.end();
    " 2>/dev/null && echo "  Instance #${inst_id}: roster delivered" || echo "  Instance #${inst_id}: delivery failed"
  done
}

start_bridge() {
  # Remove stale bridge container
  docker rm -f "$BRIDGE_CONTAINER" >/dev/null 2>&1 || true

  # Copy bridge.js into mesh dir
  local src="${SHARE_DIR}/bridge/bridge.js"
  if [[ -f "$src" ]]; then
    cp "$src" "${MESH_DIR}/bridge.js"
  elif [[ -f "${MESH_DIR}/bridge.js" ]]; then
    echo "Using existing ${MESH_DIR}/bridge.js"
  else
    echo "Error: bridge.js not found at $src" >&2
    echo "Re-run: sudo bash install.sh" >&2
    exit 1
  fi

  docker run -d \
    --name "$BRIDGE_CONTAINER" \
    --network "$NETWORK_NAME" \
    --restart unless-stopped \
    -v "${MESH_DIR}/bridge.js:/bridge/bridge.js:ro" \
    -v "${MESH_DIR}/config.json:/data/config.json:ro" \
    -e BRIDGE_PORT="$BRIDGE_INTERNAL_PORT" \
    -e RESPONSE_TIMEOUT=120000 \
    -e NODE_PATH=/app/node_modules \
    ghcr.io/openclaw/openclaw:latest \
    node /bridge/bridge.js

  echo "Bridge container started: $BRIDGE_CONTAINER"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_start() {
  echo "=== Starting OpenClaw Mesh ($NETWORK_NAME) ==="
  echo ""
  ensure_network
  echo ""
  echo "Discovering instances on $NETWORK_NAME..."
  generate_config
  echo ""
  echo "Connecting containers to mesh network..."
  connect_instances
  echo ""
  start_bridge
  echo ""
  # Wait a moment for the bridge to connect, then announce
  sleep 3
  announce_roster
  echo ""
  echo "==============================="
  echo "Mesh is running! (network: $NETWORK_NAME)"
  echo ""
  echo "From inside any instance container the agent can run:"
  echo ""
  echo "  curl -s -X POST http://${BRIDGE_CONTAINER}:3000/send \\"
  echo '    -H "Content-Type: application/json" \'
  echo '    -d '\''{"to": N, "message": "..."}'\'''
  echo ""
  echo "Endpoints:"
  echo "  GET  /health      Bridge health check"
  echo "  GET  /instances   List registered instances"
  echo "  POST /send        Send message, wait for agent response"
  echo "  POST /inject      Inject assistant message into a session"
  echo "  POST /relay       Send to B, inject response into A's session"
}

cmd_stop() {
  docker rm -f "$BRIDGE_CONTAINER" >/dev/null 2>&1 \
    && echo "Bridge stopped" \
    || echo "Bridge was not running"

  # Remove network only if no containers remain on it
  local count
  count=$(docker network inspect "$NETWORK_NAME" \
    --format '{{len .Containers}}' 2>/dev/null || echo "0")
  if [[ "$count" == "0" ]]; then
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 \
      && echo "Network removed: $NETWORK_NAME" || true
  else
    echo "Network $NETWORK_NAME still has $count container(s); keeping it"
  fi
}

cmd_status() {
  echo "=== OpenClaw Mesh Status ($NETWORK_NAME) ==="
  echo ""

  # Network info
  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "Network : $NETWORK_NAME (active)"
    echo "Containers on network:"
    docker network inspect "$NETWORK_NAME" \
      --format '{{range .Containers}}  - {{.Name}}{{"\n"}}{{end}}' 2>/dev/null || true
  else
    echo "Network : not created"
  fi
  echo ""

  # Bridge info
  if docker ps --format '{{.Names}}' | grep -qx "$BRIDGE_CONTAINER"; then
    echo "Bridge  : running"

    # Query the bridge health API
    local health
    health=$(docker exec "$BRIDGE_CONTAINER" node -e "
      const http = require('http');
      http.get('http://127.0.0.1:${BRIDGE_INTERNAL_PORT}/instances', r => {
        let d=''; r.on('data', c=>d+=c);
        r.on('end', () => console.log(d));
      });
    " 2>/dev/null || echo '{"error":"unreachable"}')
    echo "API     : $health"
  else
    echo "Bridge  : not running"
  fi
  echo ""

  # Config info
  if [[ -f "${MESH_DIR}/config.json" ]]; then
    local n
    n=$(jq '.instances | length' "${MESH_DIR}/config.json" 2>/dev/null || echo "?")
    echo "Config  : ${MESH_DIR}/config.json ($n instance(s))"
  else
    echo "Config  : not generated"
  fi
}

cmd_refresh() {
  echo "Refreshing mesh config..."
  generate_config
  echo ""

  local src="${SHARE_DIR}/bridge/bridge.js"
  if [[ -f "$src" ]]; then
    cp "$src" "${MESH_DIR}/bridge.js"
  fi

  connect_instances
  echo ""

  if docker ps --format '{{.Names}}' | grep -qx "$BRIDGE_CONTAINER"; then
    docker restart "$BRIDGE_CONTAINER"
    echo "Bridge restarted with updated config"
  else
    start_bridge
  fi

  # Announce the updated roster to all instances
  sleep 3
  announce_roster
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CMD="${1:-}"
shift 2>/dev/null || true

# Optional second argument: network name
if [[ -n "${1:-}" && "${1:-}" != -* ]]; then
  NETWORK_NAME="$1"
  shift
fi

set_network_vars

case "$CMD" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  refresh) cmd_refresh ;;
  -h|--help) usage ;;
  *)
    usage
    exit 1
    ;;
esac
