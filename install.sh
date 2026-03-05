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

mkdir -p "$BIN_DIR" "$SHARE_DIR/templates"

install -m 0755 "${REPO_DIR}/bin/openclaw-new.sh"    "${BIN_DIR}/openclaw-new"
install -m 0755 "${REPO_DIR}/bin/openclaw-delete.sh" "${BIN_DIR}/openclaw-delete"
install -m 0755 "${REPO_DIR}/bin/openclaw-update.sh" "${BIN_DIR}/openclaw-update"
install -m 0755 "${REPO_DIR}/bin/openclaw-list.sh"   "${BIN_DIR}/openclaw-list"
install -m 0755 "${REPO_DIR}/bin/openclaw-onboard.sh" "${BIN_DIR}/openclaw-onboard"

install -m 0644 "${REPO_DIR}/templates/docker-compose.yml.tmpl" "${SHARE_DIR}/templates/docker-compose.yml.tmpl"

echo "Installed openclaw manager scripts."
echo "Commands:"
echo "  openclaw-new N"
echo "  openclaw-delete N"
echo "  openclaw-onboard N"
echo "  openclaw-update N"
echo "  openclaw-list"
