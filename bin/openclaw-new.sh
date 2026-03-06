#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: openclaw-new [--pull] [--port API_PORT] N"
  echo "Example: openclaw-new 3                          (auto ports: 38789/38790)"
  echo "         openclaw-new --pull 3                   (pull latest image first)"
  echo "         openclaw-new --port 9000 7              (custom ports: 9000/9001)"
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull) PULL=true; shift ;;
    --port) CUSTOM_PORT="${2:-}"; shift 2 ;;
    *)      break ;;
  esac
done

N="${1:-}"
if ! is_int "$N" || [[ "$N" -lt 1 ]]; then
  usage; exit 1
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
INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
CONTAINER="openclaw${N}-gateway"
TZ="${TZ:-Asia/Tokyo}"

# Instances 1-6 get automatic ports; 7+ require --port
if [[ -n "$CUSTOM_PORT" ]]; then
  if ! is_int "$CUSTOM_PORT" || [[ "$CUSTOM_PORT" -lt 1024 || "$CUSTOM_PORT" -gt 65534 ]]; then
    echo "Error: port must be between 1024 and 65534."
    exit 1
  fi
  API_PORT="$CUSTOM_PORT"
  WS_PORT="$((CUSTOM_PORT + 1))"
elif [[ "$N" -le 6 ]]; then
  API_PORT="${N}8789"
  WS_PORT="${N}8790"
else
  read -r -p "Instance #$N needs custom ports. Enter API port (WS will be port+1): " CUSTOM_PORT
  if ! is_int "$CUSTOM_PORT" || [[ "$CUSTOM_PORT" -lt 1024 || "$CUSTOM_PORT" -gt 65534 ]]; then
    echo "Error: port must be between 1024 and 65534."
    exit 1
  fi
  API_PORT="$CUSTOM_PORT"
  WS_PORT="$((CUSTOM_PORT + 1))"
fi

TEMPLATE="${OPENCLAW_MGR_TEMPLATE:-/usr/local/share/openclaw-manager/templates/docker-compose.yml.tmpl}"

if [[ -d "$INSTANCE_DIR" || -d "$DATA_DIR" ]]; then
  echo "Refusing to overwrite existing instance directories:"
  echo " - $INSTANCE_DIR"
  echo " - $DATA_DIR"
  echo "Delete first (openclaw-delete $N) or clean manually."
  exit 1
fi

if port_in_use "$API_PORT" || port_in_use "$WS_PORT"; then
  echo "Port collision detected:"
  echo " - API_PORT=$API_PORT or WS_PORT=$WS_PORT already in use"
  exit 1
fi

mkdir -p "$INSTANCE_DIR" "$DATA_DIR"
# Container runs as uid 1000 (node). Create workspace with correct ownership
# without requiring sudo on the host.
docker run --rm --user root --entrypoint sh -v "${DATA_DIR}:/setup" ghcr.io/phioranex/openclaw-docker:latest \
  -c 'mkdir -p /setup/workspace && chown -R 1000:1000 /setup'

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE"
  exit 1
fi

render_template "$TEMPLATE" "${INSTANCE_DIR}/docker-compose.yml"

if [[ "$PULL" == true ]]; then
  echo "Pulling latest OpenClaw image..."
  docker pull --progress=plain ghcr.io/phioranex/openclaw-docker:latest
fi

echo "Bringing up instance #$N..."
$COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" up -d

echo ""
echo "Created OpenClaw instance #$N"
echo "Container : $CONTAINER"
echo "Compose   : $INSTANCE_DIR"
echo "Data      : $DATA_DIR"
echo "API Port  : $API_PORT"
echo "WS Port   : $WS_PORT"
echo ""
echo "Next: run onboarding"
echo "  openclaw-onboard $N"
echo ""
echo "Health:"
echo "  curl http://127.0.0.1:${API_PORT}/health"
echo "Logs:"
echo "  docker logs -f ${CONTAINER}"
