#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME:-/root}"

# Header
printf "%-22s %-14s %s\n" "INSTANCE" "PORTS" "DASHBOARD"
printf "%-22s %-14s %s\n" "--------" "-----" "---------"

# List running openclaw containers
docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^openclaw[0-9]+-gateway$' | sort | while read -r name; do
  # Extract instance number
  n=$(echo "$name" | grep -oP '(?<=openclaw)\d+')

  # Get host API port
  api_port=$(docker port "$name" 18789/tcp 2>/dev/null | head -1 | cut -d: -f2 || echo "")
  ws_port=$(docker port "$name" 18790/tcp 2>/dev/null | head -1 | cut -d: -f2 || echo "")

  # Build short port string
  ports=""
  if [[ -n "$api_port" && -n "$ws_port" ]]; then
    ports="${api_port},${ws_port}"
  elif [[ -n "$api_port" ]]; then
    ports="$api_port"
  fi

  # Check for dashboard URL (tailscale serve or fallback)
  dashboard=""
  config="${HOME_DIR}/.openclaw${n}/openclaw.json"
  if [[ -f "$config" ]]; then
    bind_val=$(sudo jq -r '.gateway.bind // "loopback"' "$config" 2>/dev/null || echo "loopback")
    token=$(sudo jq -r '.gateway.auth.token // empty' "$config" 2>/dev/null || echo "")
    token_param=""
    if [[ -n "$token" ]]; then
      token_param="?token=${token}"
    fi

    if [[ "$bind_val" == "lan" ]]; then
      # Check tailscale serve first
      if command -v tailscale >/dev/null 2>&1; then
        ts_hostname=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' 2>/dev/null | sed 's/\.$//')
        if [[ -n "$ts_hostname" && "$ts_hostname" != "null" ]]; then
          dashboard="https://${ts_hostname}:${api_port}/${token_param}"
        fi
      fi
      # Fallback to IP
      if [[ -z "$dashboard" && -n "$api_port" ]]; then
        dashboard="http://localhost:${api_port}/${token_param}"
      fi
    else
      if [[ -n "$api_port" ]]; then
        dashboard="http://localhost:${api_port}/${token_param}"
      fi
    fi
  fi

  printf "%-22s %-14s %s\n" "$name" "$ports" "$dashboard"
done
