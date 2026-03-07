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
      --arg ts_https "https://${TS_HOSTNAME}" \
      --arg ts_ip "http://${TS_IP}:${API_PORT}" \
      '["http://localhost:18789", "http://127.0.0.1:18789", $ts_https, $ts_ip]')
  else
    origins_json=$(jq -n \
      --arg ts_ip "http://${TS_IP}:${API_PORT}" \
      '["http://localhost:18789", "http://127.0.0.1:18789", $ts_ip]')
  fi

  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT

  sudo jq --argjson origins "$origins_json" '
    .gateway.bind = "lan" |
    .gateway.controlUi.allowedOrigins = $origins |
    .gateway.controlUi.allowInsecureAuth = true
  ' "$config" > "$tmp"

  if ! jq empty "$tmp" 2>/dev/null; then
    echo "Error: JSON validation failed after editing. Config unchanged."
    rm -f "$tmp"
    exit 1
  fi

  sudo mv "$tmp" "$config"
  restore_ownership "$config" "$owner"
  trap - EXIT

  echo "Config updated: gateway.bind=lan, allowedOrigins set."
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
    del(.gateway.controlUi.allowInsecureAuth) |
    if .gateway.controlUi == {} then del(.gateway.controlUi) else . end
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
          echo "Detected restrictive iptables rules. Adding Tailscale interface rule..."
          sudo iptables -I INPUT "$block_line" -i tailscale0 -j ACCEPT 2>/dev/null || {
            echo "Warning: Could not add iptables rule for tailscale0."
            echo "  You may need to run manually:"
            echo "    sudo iptables -I INPUT $block_line -i tailscale0 -j ACCEPT"
          }
        elif [[ "$input_policy" == "DROP" ]]; then
          echo "Detected DROP policy on INPUT chain. Adding Tailscale interface rule..."
          sudo iptables -A INPUT -i tailscale0 -j ACCEPT 2>/dev/null || {
            echo "Warning: Could not add iptables rule for tailscale0."
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
  local ts_serve_status
  ts_serve_status=$(sudo tailscale serve status 2>/dev/null || echo "")

  if [[ -n "$ts_serve_status" ]] && ! echo "$ts_serve_status" | grep -q ":${API_PORT}"; then
    echo "Warning: Tailscale Serve is already active for a different port."
    echo "  Only one instance can use https://${TS_HOSTNAME}/ at a time."
    echo "Current config:"
    echo "$ts_serve_status"
    echo ""
    read -r -p "Replace with port $API_PORT? [y/N] " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
      sudo tailscale serve --https=443 off 2>/dev/null || true
    else
      echo "Keeping existing Tailscale Serve config."
      echo "This instance is accessible via: http://${TS_IP}:${API_PORT}"
      return 0
    fi
  fi

  echo "Setting up Tailscale Serve (HTTPS proxy to port $API_PORT)..."
  if ! sudo tailscale serve --bg "$API_PORT" 2>&1; then
    echo "Warning: tailscale serve failed."
    echo "  Possible causes:"
    echo "  - MagicDNS not enabled (enable at https://login.tailscale.com/admin/dns)"
    echo "  - HTTPS certificates not yet provisioned (wait a minute, then retry)"
    echo "  - Tailscale Serve not available on your plan"
    echo ""
    echo "  You can still access the dashboard via: http://${TS_IP}:${API_PORT}"
  fi
}

stop_tailscale_serve() {
  sudo tailscale serve --https=443 off 2>/dev/null || true
  echo "Tailscale Serve stopped."
}

# ---------------------------------------------------------------------------
# Restart container and wait
# ---------------------------------------------------------------------------

restart_and_wait() {
  docker restart "$CONTAINER"

  echo "Waiting for gateway to start..."
  local i
  for i in $(seq 1 10); do
    if curl -sf -o /dev/null "http://127.0.0.1:${API_PORT}/" 2>/dev/null; then
      echo "Gateway is responding."
      return 0
    fi
    if [[ "$i" -eq 10 ]]; then
      echo "Warning: Gateway not responding after 10 seconds."
      echo "  Check logs: docker logs $CONTAINER --tail 20"
    fi
    sleep 1
  done
}

# ---------------------------------------------------------------------------
# Approve devices
# ---------------------------------------------------------------------------

approve_devices() {
  local pending_file="${DATA_DIR}/pending.json"
  local paired_file="${DATA_DIR}/paired.json"

  if [[ ! -f "$pending_file" ]]; then
    echo "No pending devices file found."
    return 0
  fi

  local pending_count
  pending_count=$(sudo jq 'length' "$pending_file" 2>/dev/null || echo "0")

  if [[ "$pending_count" == "0" || "$pending_count" == "null" ]]; then
    echo "No pending device pairing requests."
    return 0
  fi

  echo "Pending device pairing requests ($pending_count):"
  sudo jq -r '.[] | "  - \(.name // .id // "unknown") (\(.type // "unknown"))"' "$pending_file" 2>/dev/null || \
    sudo jq '.' "$pending_file"
  echo ""

  if [[ "$AUTO_YES" != true ]]; then
    read -r -p "Approve all $pending_count device(s)? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 0
    fi
  fi

  local owner
  owner=$(sudo stat -c '%u:%g' "$pending_file")

  # Initialize paired.json if it doesn't exist
  if [[ ! -f "$paired_file" ]]; then
    echo '[]' | sudo tee "$paired_file" >/dev/null
    restore_ownership "$paired_file" "$owner"
  fi

  local paired_owner
  paired_owner=$(sudo stat -c '%u:%g' "$paired_file")

  local ts
  ts="$(date +%s)000"

  local tmp
  tmp=$(mktemp)

  # Merge pending into paired: add approvedAt timestamp, merge with existing
  sudo jq --arg ts "$ts" '
    [.[] | . + {"approvedAt": ($ts | tonumber), "status": "approved"}]
  ' "$pending_file" > "$tmp"

  local merged
  merged=$(mktemp)
  sudo jq -s '.[0] + .[1]' "$paired_file" "$tmp" > "$merged"
  rm -f "$tmp"

  if ! jq empty "$merged" 2>/dev/null; then
    echo "Error: JSON validation failed. Pairing unchanged."
    rm -f "$merged"
    return 1
  fi

  sudo mv "$merged" "$paired_file"
  restore_ownership "$paired_file" "$paired_owner"

  # Clear pending
  local empty_tmp
  empty_tmp=$(mktemp)
  echo '[]' > "$empty_tmp"
  sudo mv "$empty_tmp" "$pending_file"
  restore_ownership "$pending_file" "$owner"

  echo "Approved $pending_count device(s)."

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
  local pending_count=0 paired_count=0
  if [[ -f "${DATA_DIR}/pending.json" ]]; then
    pending_count=$(sudo jq 'length' "${DATA_DIR}/pending.json" 2>/dev/null || echo "0")
  fi
  if [[ -f "${DATA_DIR}/paired.json" ]]; then
    paired_count=$(sudo jq 'length' "${DATA_DIR}/paired.json" 2>/dev/null || echo "0")
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
  local auth_token
  auth_token=$(sudo jq -r '.gateway.auth.token // "not set"' "$CONFIG" 2>/dev/null)

  echo ""
  echo "============================================"
  echo "Remote access enabled for OpenClaw instance #$N"
  echo "============================================"
  echo ""

  if [[ -n "$TS_HOSTNAME" ]]; then
    echo "  Dashboard URL : https://${TS_HOSTNAME}/"
  fi
  echo "  Fallback URL  : http://${TS_IP}:${API_PORT}/"
  echo "  Auth token    : $auth_token"
  echo ""
  if [[ -n "$TS_HOSTNAME" ]]; then
    echo "Open the Dashboard URL from any device on your tailnet."
    echo "When prompted for auth, paste the token shown above."
    echo "HTTPS certificates may take up to 30 seconds to provision on first use."
    echo ""
  else
    echo "Open the Fallback URL from any device on your tailnet."
    echo ""
  fi
  echo "If the browser shows \"pairing required\", run:"
  echo "  openclaw-remote $N --approve"
  echo ""
  echo "To check status:  openclaw-remote $N --status"
  echo "To disable:       openclaw-remote $N --off"
}

# ---------------------------------------------------------------------------
# Main flows
# ---------------------------------------------------------------------------

do_enable() {
  get_tailscale_info
  get_instance_info

  echo "Enabling remote access for OpenClaw instance #$N..."
  echo ""

  edit_config_enable
  setup_firewall

  if [[ -n "$TS_HOSTNAME" ]]; then
    setup_tailscale_serve
  else
    echo "Skipping Tailscale Serve (no DNS name available)."
    echo "Access the dashboard via: http://${TS_IP}:${API_PORT}"
  fi

  restart_and_wait
  print_summary
}

do_disable() {
  get_instance_info

  echo "Disabling remote access for OpenClaw instance #$N..."
  echo ""

  edit_config_disable
  stop_tailscale_serve
  restart_and_wait

  echo ""
  echo "Remote access disabled for instance #$N."
  echo "Dashboard is now only accessible from localhost: http://127.0.0.1:${API_PORT}/"
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
