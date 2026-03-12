#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/openclaw-manager"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

# Install Docker if not present
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Installing Docker..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://get.docker.com | sh
  else
    echo "Neither curl nor wget found. Cannot install Docker automatically."
    echo "Please install Docker manually: https://docs.docker.com/engine/install/"
    exit 1
  fi
  systemctl enable --now docker 2>/dev/null || true
  echo "Docker installed successfully."
else
  echo "Docker already installed: $(docker --version)"
fi

# Add the invoking user to the docker group so they can run docker without sudo
if [[ -n "${SUDO_USER:-}" ]] && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw docker; then
  usermod -aG docker "$SUDO_USER" 2>/dev/null || true
  echo "Added $SUDO_USER to the docker group. Log out and back in (or run 'newgrp docker') for this to take effect."
fi

mkdir -p "$BIN_DIR" "$SHARE_DIR/templates" "$SHARE_DIR/presets" "$SHARE_DIR/bridge"

install -m 0755 "${REPO_DIR}/bin/openclaw-new.sh"    "${BIN_DIR}/openclaw-new"
install -m 0755 "${REPO_DIR}/bin/openclaw-delete.sh" "${BIN_DIR}/openclaw-delete"
install -m 0755 "${REPO_DIR}/bin/openclaw-update.sh" "${BIN_DIR}/openclaw-update"
install -m 0755 "${REPO_DIR}/bin/openclaw-list.sh"   "${BIN_DIR}/openclaw-list"
install -m 0755 "${REPO_DIR}/bin/openclaw-onboard.sh" "${BIN_DIR}/openclaw-onboard"
install -m 0755 "${REPO_DIR}/bin/openclaw-exec.sh"    "${BIN_DIR}/openclaw-exec"
install -m 0755 "${REPO_DIR}/bin/openclaw-remote.sh"  "${BIN_DIR}/openclaw-remote"
install -m 0755 "${REPO_DIR}/bin/openclaw-logs.sh"    "${BIN_DIR}/openclaw-logs"
install -m 0755 "${REPO_DIR}/bin/openclaw-health.sh"  "${BIN_DIR}/openclaw-health"
install -m 0755 "${REPO_DIR}/bin/openclaw-help.sh"    "${BIN_DIR}/openclaw-help"
install -m 0755 "${REPO_DIR}/bin/openclaw-preset.sh"  "${BIN_DIR}/openclaw-preset"
install -m 0755 "${REPO_DIR}/bin/openclaw-watchdog.sh" "${BIN_DIR}/openclaw-watchdog"
install -m 0755 "${REPO_DIR}/bin/openclaw-mesh.sh"     "${BIN_DIR}/openclaw-mesh"

install -m 0644 "${REPO_DIR}/templates/docker-compose.yml.tmpl" "${SHARE_DIR}/templates/docker-compose.yml.tmpl"
install -m 0644 "${REPO_DIR}/bridge/bridge.js" "${SHARE_DIR}/bridge/bridge.js"

# Install preset files
for preset in "${REPO_DIR}/presets/"*.json; do
  [[ -f "$preset" ]] || continue
  install -m 0644 "$preset" "${SHARE_DIR}/presets/$(basename "$preset")"
done

# Create openclawN shortcut symlinks for existing instances
USER_HOME="${SUDO_USER:+$(eval echo "~${SUDO_USER}")}"
USER_HOME="${USER_HOME:-$HOME}"
for dir in "${USER_HOME}"/openclaw[0-9]*; do
  [[ -d "$dir" ]] || continue
  base="$(basename "$dir")"
  num="${base#openclaw}"
  [[ "$num" =~ ^[0-9]+$ ]] || continue
  shortcut="${BIN_DIR}/openclaw${num}"
  if [[ ! -e "$shortcut" ]]; then
    ln -s "${BIN_DIR}/openclaw-exec" "$shortcut"
  fi
done

echo "Installed openclaw manager scripts."
echo ""
if [[ -n "${SUDO_USER:-}" ]] && id -nG "$SUDO_USER" 2>/dev/null | grep -qw docker; then
  echo "NOTE: '$SUDO_USER' was added to the docker group."
  echo "      You must run 'newgrp docker' or log out and back in before using the commands below."
  echo ""
fi
echo "Commands:"
echo "  openclaw-new N|N-M [options]          Create instance(s) (N must be a positive integer)"
echo "  openclaw-delete N|N-M                Delete instance(s)"
echo "  openclaw-onboard N                   Run onboarding wizard"
echo "  openclaw-preset [list|show|create]   Manage config presets"
echo "  openclaw-update N                    Update instance"
echo "  openclaw-exec N [cmd...]             Run command in container"
echo "  openclaw-remote N [--off|--status]   Remote access (Tailscale)"
echo "  openclaw-logs N                      Follow container logs"
echo "  openclaw-health N                    Health check"
echo "  openclaw-watchdog N|all              Monitor & auto-restart frozen gateways"
echo "  openclaw-mesh list|start|stop|status|...        Mesh networking"
echo "  openclaw-list                        List all instances"
echo "  openclaw-help                        Full command reference"
echo ""
echo "Quick start:"
echo "  openclaw-new 1 -o                    Create + onboard interactively"
echo "  openclaw-new 2-4 --preset default    Create 3 instances, auto-configured"
echo "  openclaw-new 1 --mesh research       Create instance on a named mesh network"
echo "  openclaw-mesh join 3 research        Move instance to a different network"
echo "  openclaw-mesh leave 3                Remove instance from its mesh"
