#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-onboard N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "Data directory $DATA_DIR not found. Run openclaw-new $N first."
  exit 1
fi

echo "Running onboarding for instance #$N..."
docker run -it --rm \
  -v "${DATA_DIR}:/home/node/.openclaw" \
  -v "${DATA_DIR}/workspace:/home/node/.openclaw/workspace" \
  ghcr.io/phioranex/openclaw-docker:latest onboard
