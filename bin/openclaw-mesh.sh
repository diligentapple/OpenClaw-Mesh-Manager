#!/usr/bin/env bash
set -euo pipefail

# Source shared helpers (docker permission wrapper, compose detection)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh" 2>/dev/null \
  || source "/usr/local/lib/openclaw-manager/common.sh"

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
  list               List all mesh networks and their member instances
  start  [NETWORK]   Create mesh network, discover instances, launch bridge
  stop   [NETWORK]   Stop the bridge and (if empty) remove the network
  status [NETWORK]   Show mesh status, connected instances, bridge health
  refresh [NETWORK]  Re-discover instances, regenerate config, restart bridge
  join N [NETWORK]   Move an instance to a mesh network (refreshes both old and new)
  leave N            Remove an instance from its current mesh network

NETWORK defaults to "openclaw-net" if omitted.

Named networks let you isolate groups of instances:
  openclaw-mesh start research       # Only instances with --mesh research
  openclaw-mesh start                # Default network (openclaw-net)

Assign instances to a network when creating them:
  openclaw-new 1 --mesh research
  openclaw-new 2 --mesh research
  openclaw-new 3 --mesh ops

Or add an existing instance to a network later:
  openclaw-mesh join 1 research

Remove an instance from the mesh:
  openclaw-mesh leave 1

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
  POST /announce    Manually trigger roster broadcast to all instances
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

detect_compose_bin

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

    # Primary: read token from openclaw.json (the gateway's actual config).
    # After onboarding the wizard writes its own token here, which may differ
    # from the OPENCLAW_GATEWAY_TOKEN env var in .env.
    local cfg="${HOME_DIR}/.openclaw${num}/openclaw.json"
    if sudo test -f "$cfg" 2>/dev/null; then
      token=$(sudo jq -r '.gateway.auth.token // empty' "$cfg" 2>/dev/null || true)
    fi

    # Fallback: read from the compose .env file (pre-onboarding instances)
    if [[ -z "$token" ]] && [[ -f "$env_file" ]]; then
      token=$(grep -oP '^OPENCLAW_GATEWAY_TOKEN=\K.*' "$env_file" 2>/dev/null || true)
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
  local json='{"networkName":"'"${NETWORK_NAME}"'","bridgeHost":"'"${BRIDGE_CONTAINER}"'","bridgePort":'"${BRIDGE_INTERNAL_PORT}"',"instances":{'
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

# Write a .mesh-bridge file into each instance's data directory so the agent
# inside the container can always discover the bridge endpoint — regardless of
# whether the roster injection succeeded.
write_bridge_info() {
  for dir in "${HOME_DIR}"/openclaw[0-9]*/; do
    [[ -d "$dir" ]] || continue
    local base num inst_network
    base="$(basename "$dir")"
    num="${base#openclaw}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue

    local net_file="${HOME_DIR}/.openclaw${num}/.mesh-network"
    if [[ -f "$net_file" ]]; then
      inst_network=$(head -1 "$net_file" 2>/dev/null | tr -d '[:space:]')
    else
      inst_network="openclaw-net"
    fi
    [[ "$inst_network" == "$NETWORK_NAME" ]] || continue

    local data_dir="${HOME_DIR}/.openclaw${num}"
    local info_file="${data_dir}/.mesh-bridge"
    cat > "$info_file" <<MESHEOF
# OpenClaw Mesh Bridge — auto-generated, do not edit
# Query the bridge to discover peers and send messages.
MESH_NETWORK=${NETWORK_NAME}
BRIDGE_HOST=${BRIDGE_CONTAINER}
BRIDGE_PORT=${BRIDGE_INTERNAL_PORT}
BRIDGE_URL=http://${BRIDGE_CONTAINER}:${BRIDGE_INTERNAL_PORT}

# Discovery:
#   curl -s \${BRIDGE_URL}/instances
#
# Send a message to another instance:
#   curl -s -X POST \${BRIDGE_URL}/send -H 'Content-Type: application/json' -d '{"to": N, "message": "..."}'
MESHEOF
    # Match ownership to the data dir (container uid 1000)
    chown 1000:1000 "$info_file" 2>/dev/null || sudo chown 1000:1000 "$info_file" 2>/dev/null || true
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
      "\n\nTo message another instance: curl -s -X POST http://" + $bridge + ":3000/send -H \"Content-Type: application/json\" -d \u0027{\"to\": N, \"message\": \"...\"}\u0027 " +
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
    --restart on-failure:5 \
    --init \
    --no-healthcheck \
    --memory 128m \
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
  write_bridge_info
  echo ""
  start_bridge
  echo ""
  # Roster announcement is now handled automatically by the bridge itself.
  # When each instance connects via WebSocket, the bridge detects the state
  # change and broadcasts an updated roster to all connected peers (debounced).
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
  echo "  POST /announce    Manually trigger roster broadcast"
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
  write_bridge_info
  echo ""

  if docker ps --format '{{.Names}}' | grep -qx "$BRIDGE_CONTAINER"; then
    docker restart "$BRIDGE_CONTAINER"
    echo "Bridge restarted with updated config"
  else
    start_bridge
  fi

  # Roster announcement is handled automatically by the bridge on reconnect.
}

cmd_list() {
  echo "=== OpenClaw Mesh Networks ==="
  echo ""

  # Scan all instances to build a map of network -> instance numbers
  declare -A network_instances
  local has_any=false

  for dir in "${HOME_DIR}"/openclaw[0-9]*/; do
    [[ -d "$dir" ]] || continue
    local base num inst_network
    base="$(basename "$dir")"
    num="${base#openclaw}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue

    local net_file="${HOME_DIR}/.openclaw${num}/.mesh-network"
    if [[ -f "$net_file" ]]; then
      inst_network=$(head -1 "$net_file" 2>/dev/null | tr -d '[:space:]')
    else
      inst_network=""
    fi

    [[ -z "$inst_network" ]] && continue
    has_any=true

    if [[ -n "${network_instances[$inst_network]+x}" ]]; then
      network_instances[$inst_network]+=" $num"
    else
      network_instances[$inst_network]="$num"
    fi
  done

  if [[ "$has_any" == false ]]; then
    echo "No instances are assigned to any mesh network."
    return 0
  fi

  # Sort network names and display
  local sorted_nets
  sorted_nets=$(printf '%s\n' "${!network_instances[@]}" | sort)

  for net in $sorted_nets; do
    # Check if bridge is running for this network
    local bridge_name="openclaw-bridge"
    [[ "$net" == "openclaw-net" ]] || bridge_name="openclaw-bridge-${net}"
    local bridge_status="stopped"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$bridge_name"; then
      bridge_status="running"
    fi

    echo "$net  (bridge: $bridge_status)"

    # Sort instance numbers numerically and display each
    local sorted_nums
    sorted_nums=$(echo "${network_instances[$net]}" | tr ' ' '\n' | sort -n)
    for num in $sorted_nums; do
      local container="openclaw${num}-gateway"
      local status="stopped"
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
        status="running"
      fi

      local meta label
      meta=$(get_instance_meta "$num")
      local name="${meta%%|*}"
      local desc="${meta#*|}"
      label="#${num}"
      if [[ "$name" != "Instance ${num}" && -n "$name" ]]; then
        label+="  $name"
      fi
      if [[ -n "$desc" ]]; then
        label+="  — $desc"
      fi

      echo "  • $label  ($status)"
    done
    echo ""
  done
}

# Helper: refresh a specific network's bridge (by name), used by join/leave
# to update the old network after moving/removing an instance.
_refresh_network() {
  local net="$1"
  local saved_network="$NETWORK_NAME"
  local saved_mesh_dir="$MESH_DIR"
  local saved_bridge="$BRIDGE_CONTAINER"

  NETWORK_NAME="$net"
  set_network_vars

  if docker ps --format '{{.Names}}' | grep -qx "$BRIDGE_CONTAINER"; then
    echo "Refreshing $net mesh..."
    generate_config
    connect_instances
    docker restart "$BRIDGE_CONTAINER" >/dev/null 2>&1
    # Roster is auto-broadcast by the bridge when instances reconnect.
  fi

  NETWORK_NAME="$saved_network"
  MESH_DIR="$saved_mesh_dir"
  BRIDGE_CONTAINER="$saved_bridge"
}

cmd_join() {
  local inst_num="$1"
  local inst_dir="${HOME_DIR}/openclaw${inst_num}"
  local data_dir="${HOME_DIR}/.openclaw${inst_num}"
  local container="openclaw${inst_num}-gateway"
  local compose_file="${inst_dir}/docker-compose.yml"

  if [[ ! -d "$inst_dir" || ! -d "$data_dir" ]]; then
    echo "Error: instance #${inst_num} does not exist."
    echo "Create it first with: openclaw-new ${inst_num}"
    exit 1
  fi

  # Read current network assignment
  local old_network=""
  local net_file="${data_dir}/.mesh-network"
  if [[ -f "$net_file" ]]; then
    old_network=$(head -1 "$net_file" 2>/dev/null | tr -d '[:space:]')
  fi

  if [[ "$old_network" == "$NETWORK_NAME" ]]; then
    echo "Instance #${inst_num} is already on network $NETWORK_NAME."
    return 0
  fi

  if [[ -n "$old_network" ]]; then
    echo "Moving instance #${inst_num}: $old_network -> $NETWORK_NAME"
  else
    echo "Adding instance #${inst_num} to network $NETWORK_NAME"
  fi

  # Update the .mesh-network file
  echo "$NETWORK_NAME" | sudo tee "${net_file}" > /dev/null
  sudo chown 1000:1000 "${net_file}"

  # Ensure gateway binds to lan so the bridge can reach it over the Docker network
  local env_file="${inst_dir}/.env"
  if [[ -f "$env_file" ]]; then
    sed -i 's/^OPENCLAW_GATEWAY_BIND=.*/OPENCLAW_GATEWAY_BIND=lan/' "$env_file"
  fi

  # Patch openclaw.json with origin fallback settings required for BIND=lan
  enable_lan_gateway_config "$data_dir"

  # Update the docker-compose.yml network references
  if [[ -f "$compose_file" ]]; then
    # Replace old network references with new (normal join-to-join case)
    if [[ -n "$old_network" ]]; then
      sed -i \
        -e "s#- \"${old_network}\"#- \"${NETWORK_NAME}\"#g" \
        -e "s#^  \"${old_network}\":#  \"${NETWORK_NAME}\":#g" \
        -e "s#^    name: \"${old_network}\"#    name: \"${NETWORK_NAME}\"#g" \
        "$compose_file"
    fi

    # If the network reference is still missing (e.g. after openclaw-mesh leave),
    # add the entries back
    if ! grep -q "\- \"${NETWORK_NAME}\"" "$compose_file"; then
      sed -i "/^      - default$/a\\      - \"${NETWORK_NAME}\"" "$compose_file"
    fi
    if ! grep -q "^  \"${NETWORK_NAME}\":" "$compose_file"; then
      printf '  "%s":\n    external: true\n    name: "%s"\n' \
        "$NETWORK_NAME" "$NETWORK_NAME" >> "$compose_file"
    fi
    echo "Updated $compose_file"
  fi

  # Ensure the new network exists
  docker network create "$NETWORK_NAME" 2>/dev/null || true

  # Recreate the container so it picks up the updated .env (BIND=lan) and
  # network references from docker-compose.yml.
  if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
    echo "Recreating $container to apply network and bind changes..."
    $COMPOSE_BIN -f "$compose_file" up -d --force-recreate >/dev/null 2>&1 || true
  else
    echo "Container $container does not exist. Network will apply on next start."
  fi

  # Refresh the OLD network's bridge so it removes this instance from its roster
  if [[ -n "$old_network" ]]; then
    _refresh_network "$old_network"
  fi

  # Start or refresh the NEW network's bridge
  if docker ps --format '{{.Names}}' | grep -qx "$BRIDGE_CONTAINER"; then
    echo "Refreshing $NETWORK_NAME mesh bridge..."
    cmd_refresh
  else
    echo "Starting $NETWORK_NAME mesh bridge..."
    cmd_start
  fi
}

cmd_leave() {
  local inst_num="$1"
  local inst_dir="${HOME_DIR}/openclaw${inst_num}"
  local data_dir="${HOME_DIR}/.openclaw${inst_num}"
  local container="openclaw${inst_num}-gateway"
  local compose_file="${inst_dir}/docker-compose.yml"

  if [[ ! -d "$inst_dir" || ! -d "$data_dir" ]]; then
    echo "Error: instance #${inst_num} does not exist."
    exit 1
  fi

  # Read current network assignment
  local current_network="openclaw-net"
  local net_file="${data_dir}/.mesh-network"
  if [[ -f "$net_file" ]]; then
    current_network=$(head -1 "$net_file" 2>/dev/null | tr -d '[:space:]')
  fi

  if [[ -z "$current_network" ]]; then
    echo "Instance #${inst_num} is not part of any mesh network."
    exit 0
  fi

  echo "Removing instance #${inst_num} from mesh network $current_network"

  # Disconnect the container from the mesh network
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    docker network disconnect "$current_network" "$container" 2>/dev/null || true
    echo "$container disconnected from $current_network"
  fi

  # Remove the .mesh-network file so the instance is no longer associated
  sudo rm -f "${net_file}"

  # Remove the mesh network reference from docker-compose.yml
  if [[ -f "$compose_file" ]]; then
    sed -i \
      -e "/- \"${current_network}\"/d" \
      -e "/^  \"${current_network}\":/,/^  [^ ]/{ /^  \"${current_network}\":/d; /^    external:/d; /^    name:/d; }" \
      "$compose_file"
    echo "Updated $compose_file"
  fi

  # Refresh the network's bridge so the instance is removed from the roster
  _refresh_network "$current_network"

  echo "Instance #${inst_num} removed from mesh."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CMD="${1:-}"
shift 2>/dev/null || true

# Global flag: skip roster announcement (used by openclaw-new when instances
# aren't onboarded yet and have no active sessions to inject into).
NO_ANNOUNCE=false

# For 'join' and 'leave', the next arg is the instance number
INSTANCE_ARG=""
if [[ "$CMD" == "join" || "$CMD" == "leave" ]]; then
  if [[ -z "${1:-}" || ! "${1:-}" =~ ^[0-9]+$ ]]; then
    echo "Error: '$CMD' requires an instance number."
    echo "Usage: openclaw-mesh $CMD N${CMD:+$([[ $CMD == join ]] && echo ' [NETWORK]')}"
    exit 1
  fi
  INSTANCE_ARG="$1"
  shift
fi

# Optional argument: network name
if [[ -n "${1:-}" && "${1:-}" != -* ]]; then
  if [[ ! "$1" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Error: network name may only contain alphanumeric characters, hyphens, and underscores."
    exit 1
  fi
  NETWORK_NAME="$1"
  shift
fi

# Optional flag: --no-announce
if [[ "${1:-}" == "--no-announce" ]]; then
  NO_ANNOUNCE=true
  shift
fi

set_network_vars

case "$CMD" in
  list)    cmd_list ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  refresh) cmd_refresh ;;
  join)    cmd_join "$INSTANCE_ARG" ;;
  leave)   cmd_leave "$INSTANCE_ARG" ;;
  -h|--help) usage ;;
  *)
    usage
    exit 1
    ;;
esac
