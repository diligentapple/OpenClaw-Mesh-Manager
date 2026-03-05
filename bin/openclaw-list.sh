#!/usr/bin/env bash
set -euo pipefail
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep -E "openclaw[0-9]+-gateway|NAMES" || true
