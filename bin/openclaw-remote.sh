#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# openclaw-remote -- Configure OpenClaw instances for remote Tailscale access
# ============================================================================

usage() {
  cat <<'EOF'
Usage: openclaw-remote N [--off|--status|--approve [--yes]]

  openclaw-remote N             Enable remote access for instance N
  openclaw-remote N --off       Disable remote access for instance N
  openclaw-remote N --status    Show current remote access status
  openclaw-remote N --approve   Approve pending device pairing requests
  openclaw-remote N --approve --yes  Auto-approve without confirmation
EOF
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

install_jq() {
  if command -v jq >/dev/null 2>&1; then return 0; fi
  echo "Installing jq (required for JSON config editing)..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq jq
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y -q jq
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y -q jq
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add --quiet jq
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm jq
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y jq
  else
    echo "Error: Cannot auto-install jq. Please install it manually."
    exit 1
  fi
}

restore_ownership() {
  local file="$1" owner="$2"
  sudo chown "$owner" "$file"
  if command -v restorecon >/dev/null 2>&1; then
    sudo restorecon "$file" 2>/dev/null || true
  fi
}

# Resolve the gateway token: try openclaw.json first, fall back to the .env
# file that openclaw-new generates (the onboarding wizard may not write the
# token into the JSON config).
resolve_token() {
  local n="$1"
  local token=""

  # Try the JSON config
  if [[ -f "$CONFIG" ]]; then
    token=$(sudo jq -r '.gateway.auth.token // empty' "$CONFIG" 2>/dev/null || true)
  fi

  # Fallback: .env file created by openclaw-new
  if [[ -z "$token" ]]; then
    local env_file="${HOME_DIR}/openclaw${n}/.env"
    if [[ -f "$env_file" ]]; then
      token=$(grep -oP '^OPENCLAW_GATEWAY_TOKEN=\K.*' "$env_file" 2>/dev/null || true)
    fi
  fi

  echo "$token"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

ACTION="enable"
AUTO_YES=false
N=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --off)     ACTION="disable"; shift ;;
    --status)  ACTION="status"; shift ;;
    --approve) ACTION="approve"; shift ;;
    --yes)     AUTO_YES=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      if [[ -z "$N" ]] && is_int "$1"; then
        N="$1"; shift
      else
        echo "Error: Unknown argument '$1'"
        usage; exit 1
      fi
      ;;
  esac
done

if [[ -z "$N" ]]; then
  usage; exit 1
fi

# ---------------------------------------------------------------------------
# Instance paths
# ---------------------------------------------------------------------------

HOME_DIR="${HOME:-/root}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
CONFIG="${DATA_DIR}/openclaw.json"
CONTAINER="openclaw${N}-gateway"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

check_prerequisites() {
  install_jq

  if [[ ! -f "$CONFIG" ]]; then
    echo "Error: Instance #$N does not exist ($CONFIG not found)."
    echo "  Create it first: openclaw-new $N"
    exit 1
  fi

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    echo "Error: Container '$CONTAINER' is not running."
    echo "  Start it: docker start $CONTAINER"
    exit 1
  fi

  # Approve only needs Docker + running container, not Tailscale
  if [[ "$ACTION" == "approve" ]]; then return 0; fi

  if ! command -v tailscale >/dev/null 2>&1; then
    echo "Error: Tailscale is not installed."
    echo "  Install it: https://tailscale.com/download/linux"
    exit 1
  fi

  if ! tailscale status >/dev/null 2>&1; then
    echo "Error: Tailscale is not connected. Run 'sudo tailscale up' first."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Gather instance info
# ---------------------------------------------------------------------------

get_instance_info() {
  # Try docker port first
  API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | cut -d: -f2)

  # Fallback: docker inspect
  if [[ -z "${API_PORT:-}" ]]; then
    API_PORT=$(docker inspect "$CONTAINER" \
      --format '{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "18789/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' 2>/dev/null || echo "")
  fi

  # Fallback: read from config (host networking mode)
  if [[ -z "${API_PORT:-}" ]]; then
    API_PORT=$(sudo jq -r '.gateway.port // empty' "$CONFIG" 2>/dev/null || echo "")
  fi

  if [[ -z "${API_PORT:-}" ]]; then
    echo "Error: Cannot determine host port for instance #$N."
    echo "  Is the container running? Check: docker ps | grep openclaw${N}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Gather Tailscale info
# ---------------------------------------------------------------------------

get_tailscale_info() {
  TS_HOSTNAME=""
  TS_IP=""

  local ts_json
  ts_json=$(tailscale status --json 2>/dev/null)

  local dns_name
  dns_name=$(echo "$ts_json" | jq -r '.Self.DNSName // ""' | sed 's/\.$//')

  TS_IP=$(tailscale ip -4 2>/dev/null || echo "")

  if [[ -z "$dns_name" || "$dns_name" == "null" ]]; then
    echo "Warning: Tailscale MagicDNS may not be enabled."
    echo "  tailscale serve requires a DNS name for HTTPS certificates."
    echo "  Enable MagicDNS in your Tailscale admin console: https://login.tailscale.com/admin/dns"
    echo "  Continuing with IP-based access (HTTP only)..."
  else
    TS_HOSTNAME="$dns_name"
  fi
}

# ---------------------------------------------------------------------------
# Config editing -- Enable
# ---------------------------------------------------------------------------

edit_config_enable() {
  local config="$CONFIG"
  local owner
  owner=$(sudo stat -c '%u:%g' "$config")

  sudo cp "$config" "${config}.bak"

  local origins_json
  if [[ -n "$TS_HOSTNAME" ]]; then
    origins_json=$(jq -n \
      --arg ts_https "https://${TS_HOSTNAME}:${API_PORT}" \
      --arg ts_ip "http://${TS_IP}:${API_PORT}" \
      --arg local_api "http://localhost:${API_PORT}" \
      --arg local_loop "http://127.0.0.1:${API_PORT}" \
      '[$local_api, $local_loop, $ts_https, $ts_ip]')
  else
    origins_json=$(jq -n \
      --arg ts_ip "http://${TS_IP}:${API_PORT}" \
      --arg local_api "http://localhost:${API_PORT}" \
      --arg local_loop "http://127.0.0.1:${API_PORT}" \
      '[$local_api, $local_loop, $ts_ip]')
  fi

  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT

  # If the token is missing from the config (onboarding may not write it),
  # pull it from the .env file so the config is self-contained.
  local cfg_token
  cfg_token=$(sudo jq -r '.gateway.auth.token // empty' "$config" 2>/dev/null || true)
  if [[ -z "$cfg_token" ]]; then
    cfg_token=$(resolve_token "$N")
  fi

  if [[ -n "$cfg_token" ]]; then
    sudo jq --argjson origins "$origins_json" --arg tok "$cfg_token" '
      .gateway.bind = "lan" |
      .gateway.controlUi.allowedOrigins = $origins |
      .gateway.controlUi.allowInsecureAuth = true |
      .gateway.auth.mode = "token" |
      .gateway.auth.token = $tok |
      .gateway.remote.token = $tok
    ' "$config" > "$tmp"
  else
    sudo jq --argjson origins "$origins_json" '
      .gateway.bind = "lan" |
      .gateway.controlUi.allowedOrigins = $origins |
      .gateway.controlUi.allowInsecureAuth = true
    ' "$config" > "$tmp"
  fi

  if ! jq empty "$tmp" 2>/dev/null; then
    echo "Error: JSON validation failed after editing. Config unchanged."
    rm -f "$tmp"
    exit 1
  fi

  sudo mv "$tmp" "$config"
  restore_ownership "$config" "$owner"
  trap - EXIT

  # The container command uses --bind ${OPENCLAW_GATEWAY_BIND:-loopback} from
  # the .env file.  If we don't update .env the CLI flag overrides the JSON
  # config and the gateway stays in loopback mode.
  local env_file="${HOME_DIR}/openclaw${N}/.env"
  if [[ -f "$env_file" ]]; then
    sed -i 's/^OPENCLAW_GATEWAY_BIND=.*/OPENCLAW_GATEWAY_BIND=lan/' "$env_file"
  fi

  echo "Config updated."
}

# ---------------------------------------------------------------------------
# Config editing -- Disable
# ---------------------------------------------------------------------------

edit_config_disable() {
  local config="$CONFIG"
  local owner
  owner=$(sudo stat -c '%u:%g' "$config")

  sudo cp "$config" "${config}.bak"

  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT

  sudo jq '
    .gateway.bind = "loopback" |
    del(.gateway.controlUi.allowedOrigins) |
    del(.gateway.remote.token)
  ' "$config" > "$tmp"

  if ! jq empty "$tmp" 2>/dev/null; then
    echo "Error: JSON validation failed after editing. Restoring backup."
    sudo cp "${config}.bak" "$config"
    rm -f "$tmp"
    exit 1
  fi

  sudo mv "$tmp" "$config"
  restore_ownership "$config" "$owner"
  trap - EXIT

  # Revert .env so the container command matches the JSON config
  local env_file="${HOME_DIR}/openclaw${N}/.env"
  if [[ -f "$env_file" ]]; then
    sed -i 's/^OPENCLAW_GATEWAY_BIND=.*/OPENCLAW_GATEWAY_BIND=loopback/' "$env_file"
  fi

  echo "Config updated: gateway.bind=loopback, remote access origins removed."
}

# ---------------------------------------------------------------------------
# Firewall setup
# ---------------------------------------------------------------------------

persist_iptables() {
  # Method 1: netfilter-persistent (Ubuntu/Debian with iptables-persistent)
  if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save 2>/dev/null && return 0
  fi

  # Method 2: iptables-save to the standard Debian/Ubuntu location
  if [[ -d /etc/iptables ]]; then
    sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null && return 0
  fi

  # Method 3: iptables-save for RHEL/CentOS/Amazon Linux
  if [[ -d /etc/sysconfig ]]; then
    sudo sh -c 'iptables-save > /etc/sysconfig/iptables' 2>/dev/null && return 0
  fi

  # Method 4: Generic fallback
  if command -v iptables-save >/dev/null 2>&1; then
    sudo sh -c 'iptables-save > /etc/iptables.rules' 2>/dev/null || true
    echo "Note: iptables rule saved to /etc/iptables.rules but may not auto-load on reboot."
    echo "  Consider installing iptables-persistent: sudo apt-get install iptables-persistent"
    return 0
  fi

  echo "Warning: Could not persist iptables rules. The Tailscale rule will be lost on reboot."
  echo "  Install iptables-persistent: sudo apt-get install iptables-persistent"
}

setup_firewall() {
  local changed=false

  # Layer 1: ufw (Ubuntu/Debian firewall frontend)
  if command -v ufw >/dev/null 2>&1; then
    local ufw_status
    ufw_status=$(sudo ufw status 2>/dev/null || echo "inactive")

    if echo "$ufw_status" | grep -qi "^Status: active"; then
      if ! echo "$ufw_status" | grep -q "tailscale0"; then
        echo "Detected active ufw firewall. Adding Tailscale interface rule..."
        sudo ufw allow in on tailscale0 2>/dev/null || {
          echo "Warning: Could not add ufw rule for tailscale0."
          echo "  You may need to run manually: sudo ufw allow in on tailscale0"
        }
        changed=true
      else
        echo "ufw: Tailscale interface already allowed."
      fi
    fi
  fi

  # Layer 2: firewalld (RHEL/CentOS/Fedora/Amazon Linux 2023)
  if command -v firewall-cmd >/dev/null 2>&1; then
    local fwd_state
    fwd_state=$(sudo firewall-cmd --state 2>/dev/null || echo "not running")

    if [[ "$fwd_state" == "running" ]]; then
      if ! sudo firewall-cmd --zone=trusted --query-interface=tailscale0 2>/dev/null; then
        echo "Detected active firewalld. Adding Tailscale interface to trusted zone..."
        sudo firewall-cmd --zone=trusted --add-interface=tailscale0 --permanent 2>/dev/null || {
          echo "Warning: Could not add tailscale0 to firewalld trusted zone."
          echo "  You may need to run manually:"
          echo "    sudo firewall-cmd --zone=trusted --add-interface=tailscale0 --permanent"
          echo "    sudo firewall-cmd --reload"
        }
        sudo firewall-cmd --reload 2>/dev/null || true
        changed=true
      else
        echo "firewalld: Tailscale interface already in trusted zone."
      fi
    fi
  fi

  # Layer 3: iptables raw rules (Oracle Cloud, hardened images)
  if command -v iptables >/dev/null 2>&1; then
    local input_policy
    input_policy=$(sudo iptables -L INPUT -n 2>/dev/null \
      | head -1 | sed -n 's/.*policy \([A-Z]*\).*/\1/p')
    input_policy="${input_policy:-ACCEPT}"

    local has_block_rule=false
    if sudo iptables -L INPUT -n --line-numbers 2>/dev/null | grep -qE "REJECT|DROP"; then
      has_block_rule=true
    fi

    if [[ "$input_policy" == "DROP" || "$has_block_rule" == true ]]; then
      if ! sudo iptables -L INPUT -n 2>/dev/null | grep -q "tailscale0"; then
        local block_line
        block_line=$(sudo iptables -L INPUT -n --line-numbers 2>/dev/null \
          | grep -E "REJECT|DROP" | head -1 | awk '{print $1}')

        if [[ -n "$block_line" ]]; then
          sudo iptables -I INPUT "$block_line" -i tailscale0 -j ACCEPT 2>/dev/null || {
            echo "Warning: run manually: sudo iptables -I INPUT $block_line -i tailscale0 -j ACCEPT"
          }
        elif [[ "$input_policy" == "DROP" ]]; then
          sudo iptables -A INPUT -i tailscale0 -j ACCEPT 2>/dev/null || {
            echo "Warning: run manually: sudo iptables -A INPUT -i tailscale0 -j ACCEPT"
          }
        fi

        persist_iptables
        changed=true
      else
        echo "iptables: Tailscale interface already allowed."
      fi
    fi
  fi

  # Layer 4: nftables (newer distros, Debian 11+/Ubuntu 22.04+)
  if command -v nft >/dev/null 2>&1; then
    local nft_ruleset
    nft_ruleset=$(sudo nft list ruleset 2>/dev/null || echo "")

    if echo "$nft_ruleset" | grep -qiE "type filter.*hook input"; then
      if echo "$nft_ruleset" | grep -qiE "(policy drop|reject|drop)"; then
        if ! echo "$nft_ruleset" | grep -q "tailscale0"; then
          echo "Detected restrictive nftables rules. You may need to allow tailscale0 manually."
          echo "  Example: sudo nft add rule inet filter input iifname \"tailscale0\" accept"
        fi
      fi
    fi
  fi

  if [[ "$changed" == true ]]; then
    echo "Firewall configured for Tailscale traffic."
  fi
}

# ---------------------------------------------------------------------------
# Tailscale Serve
# ---------------------------------------------------------------------------

setup_tailscale_serve() {
  # Use the same API port for Tailscale HTTPS serve -- Tailscale intercepts
  # traffic at the WireGuard layer so it doesn't conflict with Docker's host
  # port binding on 0.0.0.0.
  #   Instance 1: https://hostname:18789/ -> 127.0.0.1:18789
  #   Instance 2: https://hostname:28789/ -> 127.0.0.1:28789
  if ! sudo tailscale serve --bg --https="$API_PORT" "http://127.0.0.1:${API_PORT}" 2>&1; then
    echo "Warning: tailscale serve failed. Use fallback: http://${TS_IP}:${API_PORT}"
  fi
}

stop_tailscale_serve() {
  sudo tailscale serve --https="$API_PORT" off 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Restart container and wait
# ---------------------------------------------------------------------------

restart_and_wait() {
  # IMPORTANT: docker restart does NOT re-read .env — env vars are baked in at
  # container creation.  We must use "docker compose up -d" to recreate the
  # container so it picks up changes to OPENCLAW_GATEWAY_BIND and other vars.
  local compose_dir="${HOME_DIR}/openclaw${N}"
  if [[ -f "${compose_dir}/docker-compose.yml" ]]; then
    docker compose -f "${compose_dir}/docker-compose.yml" up -d --force-recreate >/dev/null 2>&1
  else
    # Fallback for non-standard setups
    docker restart "$CONTAINER" >/dev/null
  fi

  local i
  for i in $(seq 1 10); do
    if curl -sf -o /dev/null "http://127.0.0.1:${API_PORT}/" 2>/dev/null; then
      return 0
    fi
    if [[ "$i" -eq 10 ]]; then
      echo "Warning: gateway not responding. Check: openclaw-logs $N --tail 20"
    fi
    sleep 1
  done
}

# ---------------------------------------------------------------------------
# Approve devices
# ---------------------------------------------------------------------------

approve_devices() {
  # Use the OpenClaw CLI inside the container to list and approve pending
  # devices.  Direct file manipulation does not work -- the gateway manages
  # its own internal state and ignores external edits to paired/pending JSON.

  # Step 1: Get pending request IDs via the CLI
  local cli_output
  cli_output=$(docker exec "$CONTAINER" node /app/dist/index.js devices list 2>&1) || true

  # Extract request IDs from the "Pending" section of CLI output.
  # The table has columns: Request | Device | Role | IP | Age | Flags
  # Request IDs are UUIDs (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).
  local request_ids
  request_ids=$(echo "$cli_output" | \
    grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | \
    sort -u) || true

  if [[ -z "$request_ids" ]]; then
    echo "No pending device pairing requests."
    echo ""
    echo "  Checked via: docker exec $CONTAINER node /app/dist/index.js devices list"
    return 0
  fi

  local pending_count
  pending_count=$(echo "$request_ids" | wc -l)

  echo "Pending device pairing requests ($pending_count):"
  echo "$request_ids" | while read -r rid; do
    echo "  - $rid"
  done
  echo ""

  if [[ "$AUTO_YES" != true ]]; then
    read -r -p "Approve all $pending_count device(s)? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 0
    fi
  fi

  local approved=0 failed=0
  while read -r rid; do
    echo "Approving $rid ..."
    if docker exec "$CONTAINER" node /app/dist/index.js devices approve "$rid" 2>&1; then
      ((approved++))
    else
      echo "  Warning: 'devices approve' failed for $rid, trying 'pairing approve' ..."
      if docker exec "$CONTAINER" node /app/dist/index.js pairing approve "$rid" 2>&1; then
        ((approved++))
      else
        echo "  Error: Could not approve $rid"
        ((failed++))
      fi
    fi
  done <<< "$request_ids"

  echo ""
  if [[ "$failed" -gt 0 ]]; then
    echo "Approved $approved device(s), $failed failed."
    echo ""
    echo "  You can try approving manually inside the container:"
    echo "    docker exec -it $CONTAINER bash"
    echo "    node /app/dist/index.js devices list"
    echo "    node /app/dist/index.js devices approve <requestId>"
    return 1
  else
    echo "Approved $approved device(s)."
  fi

  # Restart to pick up changes
  restart_and_wait
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

print_status() {
  echo "============================================"
  echo "Remote access status for OpenClaw instance #$N"
  echo "============================================"
  echo ""

  local bind_val origins_val
  bind_val=$(sudo jq -r '.gateway.bind // "not set"' "$CONFIG" 2>/dev/null)
  origins_val=$(sudo jq -r '.gateway.controlUi.allowedOrigins // [] | join(", ")' "$CONFIG" 2>/dev/null)

  echo "Config:"
  echo "  gateway.bind          : $bind_val"
  echo "  allowedOrigins        : ${origins_val:-none}"
  echo ""

  echo "Tailscale:"
  local ts_hostname ts_ip
  ts_hostname=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
  ts_ip=$(tailscale ip -4 2>/dev/null || echo "unknown")
  echo "  Hostname              : ${ts_hostname:-unknown}"
  echo "  IPv4                  : $ts_ip"

  local ts_serve
  ts_serve=$(sudo tailscale serve status 2>/dev/null || echo "")
  if [[ -n "$ts_serve" ]]; then
    echo "  Serve                 : active"
    echo "$ts_serve" | sed 's/^/    /'
  else
    echo "  Serve                 : inactive"
  fi
  echo ""

  echo "Dashboard:"
  if curl -sf -o /dev/null "http://127.0.0.1:${API_PORT}/" 2>/dev/null; then
    echo "  Responding            : yes (port $API_PORT)"
  else
    echo "  Responding            : no"
  fi
  echo ""

  echo "Devices:"
  # Use the OpenClaw CLI for accurate device counts
  local devices_output
  devices_output=$(docker exec "$CONTAINER" node /app/dist/index.js devices list 2>&1) || true
  local pending_count paired_count
  # Count lines in the Pending and Paired table sections
  pending_count=$(echo "$devices_output" | grep -cP '^│ [0-9a-f]{8}-' || echo "0")
  paired_count=$(echo "$devices_output" | grep -cP '^│ [0-9a-f]{10,}' || echo "0")
  # Fallback: parse the "Pending (N)" / "Paired (N)" headers
  if [[ "$pending_count" == "0" ]]; then
    pending_count=$(echo "$devices_output" | grep -oP 'Pending \(\K[0-9]+' || echo "0")
  fi
  if [[ "$paired_count" == "0" ]]; then
    paired_count=$(echo "$devices_output" | grep -oP 'Paired \(\K[0-9]+' || echo "0")
  fi
  echo "  Paired                : $paired_count"
  echo "  Pending               : $pending_count"
  echo ""

  echo "Firewall:"
  if command -v ufw >/dev/null 2>&1; then
    local ufw_status
    ufw_status=$(sudo ufw status 2>/dev/null | head -1 || echo "unknown")
    echo "  ufw                   : $ufw_status"
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    local fwd_state
    fwd_state=$(sudo firewall-cmd --state 2>/dev/null || echo "not running")
    echo "  firewalld             : $fwd_state"
  fi
  if command -v iptables >/dev/null 2>&1; then
    local ts_rule="no"
    if sudo iptables -L INPUT -n 2>/dev/null | grep -q "tailscale0"; then
      ts_rule="yes"
    fi
    echo "  iptables tailscale0   : $ts_rule"
  fi
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------

print_summary() {
  local gateway_token
  gateway_token=$(resolve_token "$N")

  # Build URLs with token auto-fill when available
  local token_param=""
  if [[ -n "$gateway_token" ]]; then
    token_param="?token=${gateway_token}"
  fi

  echo ""
  echo "Remote access enabled for instance #$N"
  echo ""
  if [[ -n "$TS_HOSTNAME" ]]; then
    echo "  Dashboard : https://${TS_HOSTNAME}:${API_PORT}/${token_param}"
  fi
  echo "  Fallback  : http://${TS_IP}:${API_PORT}/${token_param}"
  echo "  Token     : $gateway_token"
  echo ""
  echo "  Approve   : openclaw-remote $N --approve"
  echo "  Status    : openclaw-remote $N --status"
  echo "  Disable   : openclaw-remote $N --off"
}

# ---------------------------------------------------------------------------
# Wait for pending devices and auto-approve
# ---------------------------------------------------------------------------

wait_and_approve() {
  local timeout=120
  local interval=3
  local elapsed=0

  while [[ "$elapsed" -lt "$timeout" ]]; do
    local cli_output
    cli_output=$(docker exec "$CONTAINER" node /app/dist/index.js devices list 2>&1) || true

    local request_ids
    request_ids=$(echo "$cli_output" | \
      grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | \
      sort -u) || true

    if [[ -n "$request_ids" ]]; then
      echo ""
      local count
      count=$(echo "$request_ids" | wc -l)
      echo "Found $count pending device(s). Auto-approving..."

      local approved=0
      while read -r rid; do
        if docker exec "$CONTAINER" node /app/dist/index.js devices approve "$rid" 2>&1; then
          ((approved++))
        elif docker exec "$CONTAINER" node /app/dist/index.js pairing approve "$rid" 2>&1; then
          ((approved++))
        else
          echo "  Warning: Could not approve $rid"
        fi
      done <<< "$request_ids"

      echo "Approved $approved device(s)."
      restart_and_wait
      echo "Device paired. You can now use the dashboard."
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo ""
  echo "No devices connected within ${timeout}s."
  echo "  When ready, approve manually: openclaw-remote $N --approve"
}

# ---------------------------------------------------------------------------
# Main flows
# ---------------------------------------------------------------------------

do_enable() {
  get_tailscale_info
  get_instance_info

  edit_config_enable
  setup_firewall
  restart_and_wait

  if [[ -n "$TS_HOSTNAME" ]]; then
    setup_tailscale_serve
  fi

  print_summary

  # Poll for pending devices and auto-approve so the user can just open the
  # dashboard URL on their laptop/browser and get paired without running a
  # separate command.
  echo "Waiting for device pairing requests (open the dashboard URL above)..."
  echo "  Press Ctrl-C to stop waiting."
  echo ""
  wait_and_approve
}

do_disable() {
  get_instance_info
  edit_config_disable
  stop_tailscale_serve
  restart_and_wait
  echo "Remote access disabled. Local only: http://127.0.0.1:${API_PORT}/"
}

do_status() {
  get_instance_info
  print_status
}

do_approve() {
  get_instance_info
  approve_devices
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

check_prerequisites

case "$ACTION" in
  enable)  do_enable ;;
  disable) do_disable ;;
  status)  do_status ;;
  approve) do_approve ;;
  *)       usage; exit 1 ;;
esac
