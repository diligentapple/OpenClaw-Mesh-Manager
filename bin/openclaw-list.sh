#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME:-/root}"

# Header
printf "%-22s %-14s %s\n" "INSTANCE" "PORTS" "DASHBOARD"
printf "%-22s %-14s %s\n" "--------" "-----" "---------"

# List running openclaw containers
# Use process substitution to avoid pipefail crash when no containers match grep
while read -r name; do
  [[ -z "$name" ]] && continue
  # Extract instance number
  n=$(echo "$name" | grep -oP '(?<=openclaw)\d+')

  # Get host ports: try docker port (running), then docker inspect (any state),
  # then fall back to docker-compose.yml
  api_port=$(docker port "$name" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
  ws_port=$(docker port "$name" 18790/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)

  # Fallback: docker inspect reads port config even when stopped
  if [[ -z "$api_port" ]]; then
    api_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{if eq $p "18789/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' "$name" 2>/dev/null || true)
    ws_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{if eq $p "18790/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' "$name" 2>/dev/null || true)
  fi

  # Last resort: read from docker-compose.yml (compose dir is ~/openclawN/)
  if [[ -z "$api_port" ]]; then
    compose="${HOME_DIR}/openclaw${n}/docker-compose.yml"
    if [[ -f "$compose" ]]; then
      api_port=$(grep -oP '^\s*-\s*"\K[0-9]+(?=:18789")' "$compose" 2>/dev/null || true)
      ws_port=$(grep -oP '^\s*-\s*"\K[0-9]+(?=:18790")' "$compose" 2>/dev/null || true)
    fi
  fi

  # Build short port string
  ports=""
  if [[ -n "$api_port" && -n "$ws_port" ]]; then
    ports="${api_port},${ws_port}"
  elif [[ -n "$api_port" ]]; then
    ports="$api_port"
  fi

  # Build dashboard URL when port is known
  dashboard=""
  if [[ -n "$api_port" ]]; then
    config="${HOME_DIR}/.openclaw${n}/openclaw.json"

    # Determine bind mode (default: loopback)
    bind_val="loopback"
    if sudo test -f "$config" 2>/dev/null; then
      bind_val=$(sudo jq -r '.gateway.bind // "loopback"' "$config" 2>/dev/null || echo "loopback")
    fi

    # .env token is authoritative (it's passed to the container as an env var).
    # Fall back to the JSON config if .env is missing.
    token=""
    env_file="${HOME_DIR}/openclaw${n}/.env"
    if [[ -f "$env_file" ]]; then
      token=$(grep -oP '^OPENCLAW_GATEWAY_TOKEN=\K.*' "$env_file" 2>/dev/null || true)
    fi
    if [[ -z "$token" ]] && sudo test -f "$config" 2>/dev/null; then
      token=$(sudo jq -r '.gateway.auth.token // empty' "$config" 2>/dev/null || echo "")
    fi

    token_param=""
    [[ -n "$token" ]] && token_param="?token=${token}"

    if [[ "$bind_val" == "lan" ]]; then
      # Check tailscale first
      if command -v tailscale >/dev/null 2>&1; then
        ts_hostname=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' 2>/dev/null | sed 's/\.$//' || true)
        if [[ -n "$ts_hostname" && "$ts_hostname" != "null" ]]; then
          dashboard="https://${ts_hostname}:${api_port}/${token_param}"
        fi
      fi
      # Fallback to IP
      if [[ -z "$dashboard" ]]; then
        dashboard="http://localhost:${api_port}/${token_param}"
      fi
    else
      dashboard="http://localhost:${api_port}/${token_param}"
    fi
  fi

  printf "%-22s %-14s %s\n" "$name" "$ports" "$dashboard"
done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^openclaw[0-9]+-gateway$' | sort || true)
