#!/usr/bin/env bash
# lib/common.sh — Shared helpers for OpenClaw management scripts
#
# Source this at the top of every bin/ script (after set -euo pipefail):
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh" 2>/dev/null \
#     || source "/usr/local/lib/openclaw-manager/common.sh"

# --- Docker permission wrapper --------------------------------------------
# If the current user cannot talk to the Docker daemon directly, define a
# docker() shell function that transparently prepends sudo.  Because
# "docker compose" is a subcommand, the function intercepts both bare
# docker and docker-compose-plugin calls with zero changes to callers.
#
# IMPORTANT: bash's `exec` builtin bypasses shell functions and looks up
# external commands on PATH directly.  Use `exec_docker` (defined below)
# instead of `exec docker` when you need exec semantics with the wrapper.

_REAL_DOCKER="$(command -v docker 2>/dev/null || true)"
_DOCKER_NEEDS_SUDO=""

if [[ -n "$_REAL_DOCKER" ]]; then
  if ! "$_REAL_DOCKER" info >/dev/null 2>&1; then
    if sudo "$_REAL_DOCKER" info >/dev/null 2>&1; then
      _DOCKER_NEEDS_SUDO=1
      docker() { sudo "$_REAL_DOCKER" "$@"; }
    fi
  fi
fi

# exec_docker — use instead of `exec docker ...` so that the sudo wrapper is
# respected.  `exec` bypasses shell functions, so we resolve the real binary
# (with or without sudo) and exec that directly.
exec_docker() {
  if [[ -n "$_DOCKER_NEEDS_SUDO" ]]; then
    exec sudo "$_REAL_DOCKER" "$@"
  else
    exec "$_REAL_DOCKER" "$@"
  fi
}

# --- Memory sizing --------------------------------------------------------
# Resolve one-off container limits from host memory instead of pinning every
# workflow to the same low ceiling. This avoids V8 OOMs on onboarding/update
# runs while still leaving headroom for the host and Docker daemon.

detect_available_mem_mb() {
  local mem_kb=""
  if [[ -r /proc/meminfo ]]; then
    mem_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
    [[ -n "$mem_kb" ]] || mem_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
  fi
  if [[ -z "$mem_kb" || ! "$mem_kb" =~ ^[0-9]+$ || "$mem_kb" -le 0 ]]; then
    echo 4096
    return
  fi
  echo $((mem_kb / 1024))
}

resolve_container_memory_settings() {
  local limit_var="$1"
  local heap_var="$2"
  local min_mb="${3:-2048}"
  local max_mb="${4:-6144}"
  local reserve_mb="${5:-1024}"
  local heap_pct="${6:-80}"
  local heap_floor_mb="${7:-1536}"
  local headroom_mb="${8:-256}"
  local available_mb limit_mb heap_mb limit_value heap_value

  available_mb=$(detect_available_mem_mb)
  limit_mb=$((available_mb - reserve_mb))
  if (( limit_mb < min_mb )); then
    limit_mb=$min_mb
  elif (( limit_mb > max_mb )); then
    limit_mb=$max_mb
  fi

  heap_mb=$((limit_mb * heap_pct / 100))
  if (( heap_mb < heap_floor_mb )); then
    heap_mb=$heap_floor_mb
  fi
  if (( heap_mb > limit_mb - headroom_mb )); then
    heap_mb=$((limit_mb - headroom_mb))
  fi
  if (( heap_mb < 256 )); then
    heap_mb=256
  fi

  limit_value="${!limit_var:-${limit_mb}m}"
  heap_value="${!heap_var:-${heap_mb}}"
  printf -v "$limit_var" '%s' "$limit_value"
  printf -v "$heap_var" '%s' "$heap_value"
}

# --- LAN gateway config ---------------------------------------------------
# When the gateway binds to lan (non-loopback), it requires origin settings
# in openclaw.json.  This helper patches the config so the gateway can start.
# Call this whenever BIND is switched to lan (mesh join, onboard, etc.).

enable_lan_gateway_config() {
  local data_dir="$1"
  local config="${data_dir}/openclaw.json"

  # Config may not exist yet (pre-onboarding).  In that case, create a
  # minimal one with just the required origin settings.
  if sudo test -f "$config" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    if sudo jq '
      .gateway.controlUi.allowInsecureAuth = true |
      .gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true
    ' "$config" > "$tmp" && jq empty "$tmp" 2>/dev/null; then
      local owner
      owner=$(sudo stat -c '%u:%g' "$config")
      sudo mv "$tmp" "$config"
      sudo chown "$owner" "$config"
    else
      rm -f "$tmp"
    fi
  else
    # No config yet — write a minimal one so the gateway can start with BIND=lan
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'MINJSON'
{
  "gateway": {
    "controlUi": {
      "allowInsecureAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
MINJSON
    sudo cp "$tmp" "$config"
    sudo chown 1000:1000 "$config"
    rm -f "$tmp"
  fi
}

# --- Compose binary detection ---------------------------------------------
# Sets COMPOSE_BIN to "docker compose" (plugin) or "docker-compose" (legacy).
# Call explicitly in scripts that need compose; not run at source time.

detect_compose_bin() {
  COMPOSE_BIN="docker compose"
  if ! docker compose version >/dev/null 2>&1; then
    if command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_BIN="docker-compose"
    else
      echo "Error: Neither 'docker compose' nor 'docker-compose' found." >&2
      exit 1
    fi
  fi
}
