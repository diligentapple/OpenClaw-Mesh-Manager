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

_REAL_DOCKER="$(command -v docker 2>/dev/null || true)"

if [[ -n "$_REAL_DOCKER" ]]; then
  if ! "$_REAL_DOCKER" info >/dev/null 2>&1; then
    if sudo "$_REAL_DOCKER" info >/dev/null 2>&1; then
      docker() { sudo "$_REAL_DOCKER" "$@"; }
    fi
  fi
fi

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
