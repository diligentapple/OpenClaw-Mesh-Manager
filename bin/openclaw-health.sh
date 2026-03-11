#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-health N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

CONTAINER="openclaw${N}-gateway"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' is not running."
  echo "Use 'openclaw-list' to see running instances."
  exit 1
fi

# Determine host port for the gateway API
API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
if [[ -z "${API_PORT:-}" ]]; then
  API_PORT=$(docker inspect "$CONTAINER" \
    --format '{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "18789/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' 2>/dev/null || echo "")
fi
if [[ -z "${API_PORT:-}" ]]; then
  echo "Error: Cannot determine host port for instance #$N."
  exit 1
fi

if curl -sf "http://127.0.0.1:${API_PORT}/healthz" 2>/dev/null; then
  echo ""
else
  echo "Instance #$N is not responding on port $API_PORT."
  echo "  Check logs: openclaw-logs $N --tail 20"
  exit 1
fi
