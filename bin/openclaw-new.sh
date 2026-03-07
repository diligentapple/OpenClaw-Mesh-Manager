#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: openclaw-new [--pull] [--port API_PORT] [-o] N|N-M"
  echo "Example: openclaw-new 3                          (auto ports: 38789/38790)"
  echo "         openclaw-new 3-5                        (create instances 3, 4, 5)"
  echo "         openclaw-new --pull 3                   (pull latest image first)"
  echo "         openclaw-new --port 9000 6              (custom ports: 9000/9001)"
  echo "         openclaw-new -o 3                       (create and start onboarding)"
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
    "$tmpl" > "$out"
}

PULL=false
CUSTOM_PORT=""
ONBOARD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull) PULL=true; shift ;;
    --port) CUSTOM_PORT="${2:-}"; shift 2 ;;
    -o|--onboard) ONBOARD=true; shift ;;
    *)      break ;;
  esac
done

RANGE_ARG="${1:-}"

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

need_cmd docker
need_cmd sed

# Prefer docker compose plugin; fallback to docker-compose if user has legacy
COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  need_cmd docker-compose
  COMPOSE_BIN="docker-compose"
fi

HOME_DIR="${HOME:-/root}"
TZ="${TZ:-Asia/Tokyo}"
TEMPLATE="${OPENCLAW_MGR_TEMPLATE:-/usr/local/share/openclaw-manager/templates/docker-compose.yml.tmpl}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE"
  exit 1
fi

if [[ "$PULL" == true ]]; then
  echo "Pulling latest OpenClaw image..."
  docker pull ghcr.io/phioranex/openclaw-docker:latest
fi

# ---------------------------------------------------------------------------
# Create a single instance
# ---------------------------------------------------------------------------

create_instance() {
  N="$1"
  INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
  DATA_DIR="${HOME_DIR}/.openclaw${N}"
  CONTAINER="openclaw${N}-gateway"

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
    echo "Skipping instance #$N: already exists."
    echo " - $INSTANCE_DIR"
    echo " - $DATA_DIR"
    return 1
  fi

  if port_in_use "$API_PORT" || port_in_use "$WS_PORT"; then
    echo "Skipping instance #$N: port collision."
    echo " - API_PORT=$API_PORT or WS_PORT=$WS_PORT already in use"
    return 1
  fi

  mkdir -p "$INSTANCE_DIR" "$DATA_DIR"
  # Container runs as uid 1000 (node). Create workspace with correct ownership
  # without requiring sudo on the host.
  docker run --rm --user root --entrypoint sh -v "${DATA_DIR}:/setup" ghcr.io/phioranex/openclaw-docker:latest \
    -c 'mkdir -p /setup/workspace && chown -R 1000:1000 /setup'

  render_template "$TEMPLATE" "${INSTANCE_DIR}/docker-compose.yml"

  echo "Bringing up instance #$N..."
  $COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" up -d

  # Create shortcut symlink: openclawN -> openclaw-exec
  EXEC_BIN="$(command -v openclaw-exec 2>/dev/null || echo "/usr/local/bin/openclaw-exec")"
  SHORTCUT="/usr/local/bin/openclaw${N}"
  if [[ ! -e "$SHORTCUT" ]] && [[ -x "$EXEC_BIN" ]]; then
    ln -s "$EXEC_BIN" "$SHORTCUT" 2>/dev/null || \
      sudo ln -s "$EXEC_BIN" "$SHORTCUT" 2>/dev/null || true
  fi

  echo ""
  echo "Created OpenClaw instance #$N"
  echo "Container : $CONTAINER"
  echo "Compose   : $INSTANCE_DIR"
  echo "Data      : $DATA_DIR"
  echo "API Port  : $API_PORT"
  echo "WS Port   : $WS_PORT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CREATED=0
FAILED=0

for (( i=RANGE_START; i<=RANGE_END; i++ )); do
  if [[ "$IS_RANGE" == true ]]; then
    echo "============================================"
    echo "Creating instance #$i"
    echo "============================================"
  fi

  if create_instance "$i"; then
    ((CREATED++))
  else
    ((FAILED++))
  fi
  echo ""
done

if [[ "$IS_RANGE" == true ]]; then
  echo "Done: $CREATED created, $FAILED skipped."
  echo ""
  echo "Useful commands:"
  for (( i=RANGE_START; i<=RANGE_END; i++ )); do
    echo "  openclaw-onboard $i"
  done
else
  echo "Useful commands:"
  echo "  openclaw-onboard $RANGE_START              Run onboarding wizard"
  echo "  openclaw-health $RANGE_START               Health check"
  echo "  openclaw-logs $RANGE_START                 Follow container logs"
  echo "  openclaw${RANGE_START} <command>            Run command inside container"
  if command -v tailscale >/dev/null 2>&1; then
    echo "  openclaw-remote $RANGE_START               Enable remote access (Tailscale)"
  fi

  if [[ "$ONBOARD" == true ]]; then
    echo ""
    exec openclaw-onboard "$RANGE_START"
  fi
fi
