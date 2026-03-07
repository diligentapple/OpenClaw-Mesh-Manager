#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-logs N [--tail N]"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }
shift

CONTAINER="openclaw${N}-gateway"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' is not running."
  echo "Use 'openclaw-list' to see running instances."
  exit 1
fi

exec docker logs -f "$@" "$CONTAINER"
