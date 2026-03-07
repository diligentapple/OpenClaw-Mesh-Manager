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

mkdir -p "$BIN_DIR" "$SHARE_DIR/templates"

install -m 0755 "${REPO_DIR}/bin/openclaw-new.sh"    "${BIN_DIR}/openclaw-new"
install -m 0755 "${REPO_DIR}/bin/openclaw-delete.sh" "${BIN_DIR}/openclaw-delete"
install -m 0755 "${REPO_DIR}/bin/openclaw-update.sh" "${BIN_DIR}/openclaw-update"
install -m 0755 "${REPO_DIR}/bin/openclaw-list.sh"   "${BIN_DIR}/openclaw-list"
install -m 0755 "${REPO_DIR}/bin/openclaw-onboard.sh" "${BIN_DIR}/openclaw-onboard"
install -m 0755 "${REPO_DIR}/bin/openclaw-exec.sh"    "${BIN_DIR}/openclaw-exec"
install -m 0755 "${REPO_DIR}/bin/openclaw-remote.sh"  "${BIN_DIR}/openclaw-remote"

install -m 0644 "${REPO_DIR}/templates/docker-compose.yml.tmpl" "${SHARE_DIR}/templates/docker-compose.yml.tmpl"

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
echo "  openclaw-new N"
echo "  openclaw-delete N"
echo "  openclaw-onboard N"
echo "  openclaw-update N"
echo "  openclaw-exec N [cmd...]"
echo "  openclaw-remote N"
echo "  openclaw-list"
