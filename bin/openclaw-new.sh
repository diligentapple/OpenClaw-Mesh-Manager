#!/usr/bin/env bash
set -euo pipefail

# Source shared helpers (docker permission wrapper, compose detection)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh" 2>/dev/null \
  || source "/usr/local/lib/openclaw-manager/common.sh"

usage() {
  echo "Usage: openclaw-new [options] N|N-M [--preset NAME]"
  echo ""
  echo "Examples:"
  echo "  openclaw-new 3                          Create instance 3 (ports 38789/38790)"
  echo "  openclaw-new 2-4                        Create instances 2, 3, 4"
  echo "  openclaw-new 2-4 --preset default       Create + auto-configure (no onboarding)"
  echo "  openclaw-new --pull 3                   Pull latest image first"
  echo "  openclaw-new --port 9000 6              Custom ports: 9000/9001"
  echo "  openclaw-new -o 3                       Create and start onboarding"
  echo ""
  echo "Options:"
  echo "  --pull            Pull latest Docker image before creating"
  echo "  --port PORT       Use a custom API port (WS = PORT+1)"
  echo "  --mesh NAME       Join a named mesh network (default: openclaw-net)"
  echo "  -o, --onboard     Start interactive onboarding after creation"
  echo "  --preset NAME     Skip onboarding, apply a preset config"
  echo ""
  echo "Available presets:"
  local pdir="${OPENCLAW_MGR_PRESETS:-/usr/local/share/openclaw-manager/presets}"
  if [[ -d "$pdir" ]]; then
    for f in "$pdir"/*.json; do
      [[ -f "$f" ]] || continue
      echo "  $(basename "$f" .json)"
    done
  else
    echo "  (none found)"
  fi
  echo ""
  echo "Create your own presets with: openclaw-preset"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

port_in_use() {
  local p="$1"
  # ss is most common on Ubuntu; fallback to lsof if needed
  if command -v ss >/dev/null 2>&1; then
    ss -lnt | awk '{print $4}' | grep -qE ":${p}$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP -sTCP:LISTEN -nP | grep -q ":${p} "
  else
    return 1
  fi
}

render_template() {
  local tmpl="$1" out="$2"
  sed \
    -e "s/{{N}}/${N}/g" \
    -e "s/{{API_PORT}}/${API_PORT}/g" \
    -e "s/{{WS_PORT}}/${WS_PORT}/g" \
    -e "s#{{DATA_DIR}}#${DATA_DIR}#g" \
    -e "s#{{TZ}}#${TZ}#g" \
    -e "s#{{MESH_NETWORK}}#${MESH_NETWORK}#g" \
    "$tmpl" > "$out"
}

write_gateway_env() {
  local env_file="$1"
  local gw_token="$2"
  local gateway_bind="${3:-loopback}"
  local instance_count="$4"

  resolve_gateway_runtime_memory_settings OPENCLAW_GATEWAY_MEMORY_LIMIT OPENCLAW_GATEWAY_NODE_HEAP_MB "$instance_count"

  cat > "$env_file" <<ENVEOF
OPENCLAW_GATEWAY_TOKEN=${gw_token}
OPENCLAW_GATEWAY_BIND=${gateway_bind}
OPENCLAW_GATEWAY_MEMORY_LIMIT=${OPENCLAW_GATEWAY_MEMORY_LIMIT}
OPENCLAW_GATEWAY_NODE_HEAP_MB=${OPENCLAW_GATEWAY_NODE_HEAP_MB}
ENVEOF
}

PULL=false
CUSTOM_PORT=""
ONBOARD=false
PRESET=""
RANGE_ARG=""
MESH_NETWORK="openclaw-net"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull) PULL=true; shift ;;
    --port) [[ $# -ge 2 ]] || { echo "Error: --port requires a value"; exit 1; }; CUSTOM_PORT="$2"; shift 2 ;;
    --mesh) [[ $# -ge 2 ]] || { echo "Error: --mesh requires a name"; exit 1; }
      if [[ ! "$2" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Error: mesh network name may only contain alphanumeric characters, hyphens, and underscores."; exit 1
      fi
      MESH_NETWORK="$2"; shift 2 ;;
    -o|--onboard) ONBOARD=true; shift ;;
    --preset) [[ $# -ge 2 ]] || { echo "Error: --preset requires a value"; exit 1; }; PRESET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$RANGE_ARG" ]]; then
        RANGE_ARG="$1"
      else
        echo "Error: unexpected argument '$1'"
        usage; exit 1
      fi
      shift
      ;;
  esac
done

# Parse N or N-M range
if [[ "$RANGE_ARG" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  RANGE_START="${BASH_REMATCH[1]}"
  RANGE_END="${BASH_REMATCH[2]}"
  if [[ "$RANGE_START" -lt 1 || "$RANGE_END" -lt "$RANGE_START" ]]; then
    echo "Error: invalid range $RANGE_ARG (start must be >= 1 and <= end)"
    exit 1
  fi
  IS_RANGE=true
elif is_int "$RANGE_ARG" && [[ "$RANGE_ARG" -ge 1 ]]; then
  RANGE_START="$RANGE_ARG"
  RANGE_END="$RANGE_ARG"
  IS_RANGE=false
else
  usage; exit 1
fi

# Ranges don't support --port or -o
if [[ "$IS_RANGE" == true ]]; then
  if [[ -n "$CUSTOM_PORT" ]]; then
    echo "Error: --port cannot be used with a range. Each instance gets automatic ports."
    exit 1
  fi
  if [[ "$ONBOARD" == true ]]; then
    echo "Error: -o/--onboard cannot be used with a range. Onboard each instance separately."
    exit 1
  fi
fi

# --preset and -o are mutually exclusive
if [[ -n "$PRESET" && "$ONBOARD" == true ]]; then
  echo "Error: --preset and -o/--onboard cannot be used together."
  exit 1
fi

# Resolve preset file
PRESET_FILE=""
if [[ -n "$PRESET" ]]; then
  PRESET_DIR="${OPENCLAW_MGR_PRESETS:-/usr/local/share/openclaw-manager/presets}"
  PRESET_FILE="${PRESET_DIR}/${PRESET}.json"
  if [[ ! -f "$PRESET_FILE" ]]; then
    echo "Error: preset '$PRESET' not found at $PRESET_FILE"
    exit 1
  fi
fi

need_cmd docker
need_cmd sed

detect_compose_bin

HOME_DIR="${HOME:-/root}"
TZ="${TZ:-Asia/Tokyo}"
TEMPLATE="${OPENCLAW_MGR_TEMPLATE:-/usr/local/share/openclaw-manager/templates/docker-compose.yml.tmpl}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE"
  exit 1
fi

TARGET_INSTANCE_COUNT=$(count_openclaw_instances)
for (( i=RANGE_START; i<=RANGE_END; i++ )); do
  if [[ ! -d "${HOME_DIR}/openclaw${i}" && ! -d "${HOME_DIR}/.openclaw${i}" ]]; then
    ((TARGET_INSTANCE_COUNT++)) || true
  fi
done

OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:latest"

if [[ "$PULL" == true ]]; then
  echo "Pulling latest OpenClaw image..."
  docker pull "$OPENCLAW_IMAGE"
fi

# ---------------------------------------------------------------------------
# Apply a preset: render template and write openclaw.json directly
# ---------------------------------------------------------------------------

SHARE_DIR="${OPENCLAW_MGR_SHARE:-/usr/local/share/openclaw-manager}"

gen_token() {
  # 24-byte hex token (48 chars)
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Prompt for API key on first use of a preset that contains {{API_KEY}},
# then cache it so subsequent instances reuse the same key.
resolve_api_key() {
  local preset_file="$1"

  # Check if preset uses the {{API_KEY}} placeholder at all
  if ! grep -q '{{API_KEY}}' "$preset_file"; then
    API_KEY=""
    return
  fi

  local cache_file="${SHARE_DIR}/.api_key"

  # Already cached?
  if [[ -f "$cache_file" ]]; then
    API_KEY=$(sudo cat "$cache_file")
    if [[ -n "$API_KEY" ]]; then
      return
    fi
  fi

  # First time — prompt
  echo ""
  read -r -p "Enter your LLM API key (e.g. OpenRouter): " API_KEY
  if [[ -z "$API_KEY" ]]; then
    echo "Warning: empty API key. Instances won't be able to call the LLM."
    echo "         You can set it later in each instance's openclaw.json."
    return
  fi

  # Cache for future preset uses
  sudo tee "$cache_file" > /dev/null <<< "$API_KEY"
  sudo chmod 600 "$cache_file"
  echo "API key saved for future preset uses."
}

apply_preset() {
  local n="$1" api_port="$2" data_dir="$3" preset_file="$4"
  local config="${data_dir}/openclaw.json"
  local token
  token=$(gen_token)
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

  # Render preset template with instance-specific values.
  # API_KEY may contain sed metacharacters (|, &, \), so use awk for safe
  # literal replacement of all placeholders.
  local tmp
  tmp=$(mktemp)
  awk \
    -v api_port="$api_port" \
    -v token="$token" \
    -v timestamp="$timestamp" \
    -v api_key="$API_KEY" \
    '{
      gsub(/\{\{API_PORT\}\}/, api_port)
      gsub(/\{\{TOKEN\}\}/, token)
      gsub(/\{\{TIMESTAMP\}\}/, timestamp)
      gsub(/\{\{API_KEY\}\}/, api_key)
      print
    }' "$preset_file" > "$tmp"

  # Data dir is owned by uid 1000 (container node user), so use sudo
  sudo cp "$tmp" "$config"
  sudo chown 1000:1000 "$config"
  rm -f "$tmp"

  # If the preset sets bind=lan, update the .env so the gateway command matches
  # and patch openclaw.json with origin settings required for non-loopback binding
  local instance_dir="${HOME_DIR}/openclaw${n}"
  if grep -q '"bind": "lan"' "$preset_file"; then
    sed -i 's/^OPENCLAW_GATEWAY_BIND=.*/OPENCLAW_GATEWAY_BIND=lan/' "${instance_dir}/.env"
    enable_lan_gateway_config "$data_dir"
  fi

  # Ensure the shared mesh network exists (idempotent)
  docker network create "$MESH_NETWORK" 2>/dev/null || true

  # Restart to pick up new config
  local container="openclaw${n}-gateway"
  $COMPOSE_BIN -f "${instance_dir}/docker-compose.yml" up -d --force-recreate >/dev/null 2>&1 || true

  echo "Preset '${PRESET}' applied (token: ${token:0:12}...)"
}

# ---------------------------------------------------------------------------
# Create a single instance
# ---------------------------------------------------------------------------

create_instance() {
  N="$1"
  INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
  DATA_DIR="${HOME_DIR}/.openclaw${N}"
  CONTAINER="openclaw${N}-gateway"
  local instance_count
  instance_count="${TARGET_INSTANCE_COUNT:-$(count_openclaw_instances)}"
  local should_start_gateway=false
  if [[ -n "$PRESET_FILE" ]]; then
    should_start_gateway=true
  fi

  # Port assignment
  if [[ -n "$CUSTOM_PORT" ]]; then
    if ! is_int "$CUSTOM_PORT" || [[ "$CUSTOM_PORT" -lt 1024 || "$CUSTOM_PORT" -gt 65534 ]]; then
      echo "Error: port must be between 1024 and 65534."
      return 1
    fi
    API_PORT="$CUSTOM_PORT"
    WS_PORT="$((CUSTOM_PORT + 1))"
  elif [[ "$N" -le 5 ]]; then
    API_PORT="${N}8789"
    WS_PORT="${N}8790"
  else
    read -r -p "Instance #$N needs custom ports. Enter API port (WS will be port+1): " CUSTOM_PORT
    if ! is_int "$CUSTOM_PORT" || [[ "$CUSTOM_PORT" -lt 1024 || "$CUSTOM_PORT" -gt 65534 ]]; then
      echo "Error: port must be between 1024 and 65534."
      return 1
    fi
    API_PORT="$CUSTOM_PORT"
    WS_PORT="$((CUSTOM_PORT + 1))"
  fi

  if [[ -d "$INSTANCE_DIR" || -d "$DATA_DIR" ]]; then
    # Directories exist — check if the container is also present
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
      echo "Skipping instance #$N: already exists."
      echo " - $INSTANCE_DIR"
      echo " - $DATA_DIR"
      return 1
    fi

    # Directories exist but no container — recover by re-creating the container
    echo "Instance #$N directories exist but container is missing. Recovering..."
    mkdir -p "$INSTANCE_DIR" "$DATA_DIR"

    # Ensure data dirs have correct ownership
    docker run --rm --user root --entrypoint sh -v "${DATA_DIR}:/setup" "$OPENCLAW_IMAGE" \
      -c 'mkdir -p /setup/workspace /setup/identity && chown -R 1000:1000 /setup'
    # Allow host user to traverse the data dir (owned by container uid 1000)
    chmod o+rx "$DATA_DIR"

    # Re-render compose file (in case template was updated)
    render_template "$TEMPLATE" "${INSTANCE_DIR}/docker-compose.yml"

    # Re-write .env only if missing (preserve existing token)
    if [[ ! -f "${INSTANCE_DIR}/.env" ]]; then
      local gw_token
      gw_token=$(gen_token)
      write_gateway_env "${INSTANCE_DIR}/.env" "$gw_token" "loopback" "$instance_count"
    else
      resolve_gateway_runtime_memory_settings OPENCLAW_GATEWAY_MEMORY_LIMIT OPENCLAW_GATEWAY_NODE_HEAP_MB "$instance_count"
      upsert_env_var "${INSTANCE_DIR}/.env" "OPENCLAW_GATEWAY_MEMORY_LIMIT" "${OPENCLAW_GATEWAY_MEMORY_LIMIT}"
      upsert_env_var "${INSTANCE_DIR}/.env" "OPENCLAW_GATEWAY_NODE_HEAP_MB" "${OPENCLAW_GATEWAY_NODE_HEAP_MB}"
    fi

    # Update mesh network assignment if --mesh was given
    echo "$MESH_NETWORK" > "${DATA_DIR}/.mesh-network"

    docker network create "$MESH_NETWORK" 2>/dev/null || true

    if [[ "$should_start_gateway" == true ]]; then
      echo "Starting instance #$N..."
      $COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" up -d
    else
      echo "Creating container for instance #$N (gateway will stay stopped until onboarding)..."
      $COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" create
    fi
  else
    # Fresh creation
    if port_in_use "$API_PORT" || port_in_use "$WS_PORT"; then
      echo "Skipping instance #$N: port collision."
      echo " - API_PORT=$API_PORT or WS_PORT=$WS_PORT already in use"
      return 1
    fi

    mkdir -p "$INSTANCE_DIR" "$DATA_DIR"

    # Store the mesh network assignment for this instance (before docker chown)
    echo "$MESH_NETWORK" > "${DATA_DIR}/.mesh-network"

    # Container runs as uid 1000 (node). Create workspace and identity dirs
    # with correct ownership without requiring sudo on the host.
    docker run --rm --user root --entrypoint sh -v "${DATA_DIR}:/setup" "$OPENCLAW_IMAGE" \
      -c 'mkdir -p /setup/workspace /setup/identity && chown -R 1000:1000 /setup'
    # Allow host user to traverse the data dir (owned by container uid 1000)
    chmod o+rx "$DATA_DIR"

    render_template "$TEMPLATE" "${INSTANCE_DIR}/docker-compose.yml"

    # Generate per-instance .env file for docker compose
    # Start with loopback binding so the gateway can start without requiring
    # allowedOrigins config.  Switched to lan during onboarding/mesh-join
    # when the full config is written.
    local gw_token
    gw_token=$(gen_token)
    write_gateway_env "${INSTANCE_DIR}/.env" "$gw_token" "loopback" "$instance_count"

    # Ensure the shared mesh network exists (idempotent)
    docker network create "$MESH_NETWORK" 2>/dev/null || true

    if [[ "$should_start_gateway" == true ]]; then
      echo "Starting instance #$N..."
      $COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" up -d
    else
      echo "Creating container for instance #$N (gateway will stay stopped until onboarding)..."
      $COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" create
    fi
  fi

  # Create shortcut symlink: openclawN -> openclaw-exec
  EXEC_BIN="$(command -v openclaw-exec 2>/dev/null || echo "/usr/local/bin/openclaw-exec")"
  SHORTCUT="/usr/local/bin/openclaw${N}"
  if [[ ! -e "$SHORTCUT" ]] && [[ -x "$EXEC_BIN" ]]; then
    ln -s "$EXEC_BIN" "$SHORTCUT" 2>/dev/null || \
      sudo ln -s "$EXEC_BIN" "$SHORTCUT" 2>/dev/null || true
  fi

  # Apply preset if specified
  if [[ -n "$PRESET_FILE" ]]; then
    apply_preset "$N" "$API_PORT" "$DATA_DIR" "$PRESET_FILE"
  fi

  echo ""
  echo "Created OpenClaw instance #$N"
  echo "Container : $CONTAINER"
  echo "Compose   : $INSTANCE_DIR"
  echo "Data      : $DATA_DIR"
  echo "API Port  : $API_PORT"
  echo "WS Port   : $WS_PORT"
  if [[ "$should_start_gateway" == true ]]; then
    echo "Gateway   : running"
  else
    echo "Gateway   : created, not started"
  fi
  if [[ "$MESH_NETWORK" != "openclaw-net" ]]; then
    echo "Network   : $MESH_NETWORK"
  fi

  # Do NOT start the mesh bridge here.  Instances aren't onboarded yet and
  # can't handle roster injection — the bridge would connect, inject a roster
  # message into unconfigured gateways, and potentially crash them.  The bridge
  # is started later by openclaw-onboard (after the gateway is configured) or
  # manually via openclaw-mesh start.
  echo ""
  echo "Mesh bridge will start automatically during onboarding."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CREATED=0
FAILED=0

# Prompt for API key once before creating any instances
API_KEY=""
if [[ -n "$PRESET_FILE" ]]; then
  resolve_api_key "$PRESET_FILE"
fi

for (( i=RANGE_START; i<=RANGE_END; i++ )); do
  if [[ "$IS_RANGE" == true ]]; then
    echo "============================================"
    echo "Creating instance #$i"
    echo "============================================"
  fi

  if create_instance "$i"; then
    ((CREATED++)) || true
  else
    ((FAILED++)) || true
  fi
  echo ""
done

if [[ "$IS_RANGE" == true ]]; then
  echo "Done: $CREATED created, $FAILED skipped."
  echo ""
  echo "Useful commands:"
  if [[ -z "$PRESET_FILE" ]]; then
    for (( i=RANGE_START; i<=RANGE_END; i++ )); do
      echo "  openclaw-onboard $i"
    done
  else
    for (( i=RANGE_START; i<=RANGE_END; i++ )); do
      echo "  openclaw-health $i"
    done
  fi
else
  echo "Useful commands:"
  if [[ -z "$PRESET_FILE" ]]; then
    echo "  openclaw-onboard $RANGE_START              Run onboarding wizard"
  else
    echo "  openclaw-health $RANGE_START               Health check"
    echo "  openclaw-logs $RANGE_START                 Follow container logs"
    echo "  openclaw${RANGE_START} <command>            Run command inside container"
    if command -v tailscale >/dev/null 2>&1; then
      echo "  openclaw-remote $RANGE_START               Enable remote access (Tailscale)"
    fi
  fi

  if [[ "$ONBOARD" == true ]]; then
    echo ""
    exec openclaw-onboard "$RANGE_START"
  fi
fi
