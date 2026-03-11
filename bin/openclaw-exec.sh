#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: openclaw-exec N <command> [args...]"
  echo "       openclaw-exec N            (opens interactive shell)"
  echo ""
  echo "Run a command inside OpenClaw instance N's container."
  echo ""
  echo "Examples:"
  echo "  openclaw-exec 1                                       (interactive shell)"
  echo "  openclaw-exec 1 pairing approve telegram ABC123       (openclaw subcommand)"
  echo "  openclaw-exec 2 node --version                        (system binary)"
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
  # If the first argument is a system binary (bash, node, cat, …)
  # run it directly.  Otherwise treat it as an OpenClaw CLI subcommand
  # and route through the app entrypoint.
  if docker exec "$CONTAINER" sh -c "command -v \"$1\"" >/dev/null 2>&1; then
    exec docker exec "$CONTAINER" "$@"
  else
    exec docker exec "$CONTAINER" node /app/dist/index.js "$@"
  fi
fi
