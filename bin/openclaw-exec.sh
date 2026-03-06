#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: openclaw-exec N <command> [args...]"
  echo "       openclaw-exec N            (opens interactive shell)"
  echo ""
  echo "Run a command inside OpenClaw instance N's container."
  echo ""
  echo "Examples:"
  echo "  openclaw-exec 1                       (interactive shell)"
  echo "  openclaw-exec 2 node --version"
  echo "  openclaw-exec 3 cat /app/config.json"
}

# Support being called as "openclawN" symlink (extract N from command name)
SELF="$(basename "$0")"
if [[ "$SELF" =~ ^openclaw([0-9]+)$ ]]; then
  N="${BASH_REMATCH[1]}"
else
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
  fi

  N="${1:-}"
  if [[ -z "$N" ]] || ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 1 ]]; then
    usage; exit 1
  fi
  shift
fi

CONTAINER="openclaw${N}-gateway"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' is not running."
  echo "Use 'openclaw-list' to see running instances."
  exit 1
fi

if [[ $# -eq 0 ]]; then
  exec docker exec -it "$CONTAINER" bash
else
  exec docker exec "$CONTAINER" "$@"
fi
