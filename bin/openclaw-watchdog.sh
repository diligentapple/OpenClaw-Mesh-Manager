#!/usr/bin/env bash
set -euo pipefail

# Source shared helpers (docker permission wrapper, compose detection)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh" 2>/dev/null \
  || source "/usr/local/lib/openclaw-manager/common.sh"

usage() {
  echo "Usage: openclaw-watchdog [options] N|all"
  echo ""
  echo "Monitor OpenClaw instances and restart frozen gateways."
  echo "A gateway is considered frozen if it produces no log output"
  echo "within the silence threshold (default: 10 minutes)."
  echo ""
  echo "Options:"
  echo "  --install          Install as a cron job (runs every 5 minutes)"
  echo "  --uninstall        Remove the cron job"
  echo "  --threshold MINS   Minutes of log silence before restart (default: 10)"
  echo "  --dry-run          Report status but don't restart"
  echo ""
  echo "Examples:"
  echo "  openclaw-watchdog 1                Check instance 1"
  echo "  openclaw-watchdog all              Check all running instances"
  echo "  openclaw-watchdog --install all    Install cron for all instances"
  echo "  openclaw-watchdog --uninstall      Remove cron job"
}

THRESHOLD=10
DRY_RUN=false
INSTALL=false
UNINSTALL=false
TARGET=""
CRON_TAG="# openclaw-watchdog"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    --threshold) THRESHOLD="${2:-10}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      else
        echo "Error: unexpected argument '$1'"; usage; exit 1
      fi
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Cron management
# ---------------------------------------------------------------------------

if [[ "$UNINSTALL" == true ]]; then
  crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
  echo "Watchdog cron job removed."
  exit 0
fi

if [[ "$INSTALL" == true ]]; then
  [[ -z "$TARGET" ]] && { echo "Error: specify N or 'all'"; exit 1; }
  SELF="$(command -v openclaw-watchdog 2>/dev/null || echo "/usr/local/bin/openclaw-watchdog")"
  CRON_LINE="*/5 * * * * ${SELF} --threshold ${THRESHOLD} ${TARGET} >> /tmp/openclaw-watchdog.log 2>&1 ${CRON_TAG}"

  # Remove old entry, add new one
  { crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true; echo "$CRON_LINE"; } | crontab -
  echo "Watchdog cron job installed (every 5 minutes, threshold=${THRESHOLD}m)."
  echo "Logs: /tmp/openclaw-watchdog.log"
  exit 0
fi

# ---------------------------------------------------------------------------
# Main check
# ---------------------------------------------------------------------------

[[ -z "$TARGET" ]] && { usage; exit 1; }

detect_compose_bin

HOME_DIR="${HOME:-/root}"

ensure_mesh_network() {
  local n="$1"
  local container="openclaw${n}-gateway"
  local data_dir="${HOME_DIR}/.openclaw${n}"
  local net_file="${data_dir}/.mesh-network"

  # Skip if not assigned to a mesh network
  [[ -f "$net_file" ]] || return 0
  local mesh_network
  mesh_network=$(head -1 "$net_file" 2>/dev/null | tr -d '[:space:]')
  [[ -n "$mesh_network" ]] || return 0

  # Skip if container isn't running
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    return 0
  fi

  # Check if the container is on the mesh network
  local connected_list
  connected_list=$(docker network inspect "$mesh_network" \
    --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)

  if ! echo "$connected_list" | grep -q "$container"; then
    echo "$(date -Iseconds) [watchdog] Instance #$n: not on mesh network $mesh_network — reconnecting..."
    if [[ "$DRY_RUN" == true ]]; then
      echo "$(date -Iseconds) [watchdog] Instance #$n: would reconnect to $mesh_network (dry-run)."
      return 0
    fi
    docker network connect "$mesh_network" "$container" 2>/dev/null \
      && echo "$(date -Iseconds) [watchdog] Instance #$n: reconnected to $mesh_network." \
      || echo "$(date -Iseconds) [watchdog] Instance #$n: FAILED to reconnect to $mesh_network."
  fi
}

check_instance() {
  local n="$1"
  local container="openclaw${n}-gateway"
  local instance_dir="${HOME_DIR}/openclaw${n}"
  local compose_file="${instance_dir}/docker-compose.yml"

  # Ensure mesh network attachment (even for running containers)
  ensure_mesh_network "$n"

  # Skip if container isn't running
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    return 0
  fi

  # Get the most recent log line timestamp
  local last_log
  last_log=$(docker logs "$container" --since "${THRESHOLD}m" 2>&1 | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' | tail -1 || true)

  if [[ -n "$last_log" ]]; then
    # Container has recent log output — it's alive
    return 0
  fi

  # No log output in THRESHOLD minutes — check if healthz actually responds in time
  local api_port
  api_port=$(docker port "$container" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
  if [[ -n "$api_port" ]]; then
    # Use a tight 3-second timeout to detect frozen event loops
    if curl -sf --max-time 3 "http://127.0.0.1:${api_port}/healthz" >/dev/null 2>&1; then
      # healthz responds but no log activity — likely frozen (processing queue stuck)
      # Additional check: try a real API call that exercises more of the gateway
      local status_check
      status_check=$(curl -sf --max-time 5 "http://127.0.0.1:${api_port}/api/status" 2>/dev/null || true)
      if [[ -n "$status_check" ]]; then
        # API still responds — might just be idle (no messages to process)
        return 0
      fi
    fi
  fi

  # Gateway is frozen or unresponsive
  echo "$(date -Iseconds) [watchdog] Instance #$n: no activity for ${THRESHOLD}m — gateway appears frozen."

  if [[ "$DRY_RUN" == true ]]; then
    echo "$(date -Iseconds) [watchdog] Instance #$n: would restart (dry-run)."
    return 0
  fi

  echo "$(date -Iseconds) [watchdog] Instance #$n: restarting..."

  # Remove stale lock/pid files that survive container restarts
  local data_dir="${HOME_DIR}/.openclaw${n}"
  rm -f "${data_dir}"/*.lock "${data_dir}"/*.pid 2>/dev/null || true

  if [[ -f "$compose_file" ]]; then
    $COMPOSE_BIN --project-directory "$instance_dir" \
      -f "$compose_file" up -d --force-recreate 2>&1 | grep -v "^$" || true
  else
    docker restart "$container" >/dev/null 2>&1 || true
  fi

  # Wait for it to come back
  local i
  for i in $(seq 1 30); do
    if [[ -n "$api_port" ]] && curl -sf --max-time 3 "http://127.0.0.1:${api_port}/healthz" >/dev/null 2>&1; then
      echo "$(date -Iseconds) [watchdog] Instance #$n: restarted and healthy."
      # Verify mesh network attachment after restart
      ensure_mesh_network "$n"
      return 0
    fi
    sleep 1
  done

  # Even if health check fails, try to ensure mesh network attachment
  ensure_mesh_network "$n"
  echo "$(date -Iseconds) [watchdog] Instance #$n: restarted but health check failed after 30s."
}

if [[ "$TARGET" == "all" ]]; then
  # Find all running openclaw containers
  for container in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^openclaw[0-9]+-gateway$' || true); do
    n="${container#openclaw}"
    n="${n%-gateway}"
    check_instance "$n"
  done
else
  if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    echo "Error: N must be a number or 'all'"
    exit 1
  fi
  check_instance "$TARGET"
fi
