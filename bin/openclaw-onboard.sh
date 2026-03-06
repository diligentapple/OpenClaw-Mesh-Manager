#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-onboard N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

CONTAINER="openclaw${N}-gateway"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Container $CONTAINER not found. Run openclaw-new $N first."
  exit 1
fi

echo "Running onboarding for instance #$N..."
docker exec -it "$CONTAINER" onboard
