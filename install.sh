#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/openclaw-manager"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

mkdir -p "$BIN_DIR" "$SHARE_DIR/templates"

install -m 0755 "${REPO_DIR}/bin/openclaw-new.sh"    "${BIN_DIR}/openclaw-new"
install -m 0755 "${REPO_DIR}/bin/openclaw-delete.sh" "${BIN_DIR}/openclaw-delete"
install -m 0755 "${REPO_DIR}/bin/openclaw-update.sh" "${BIN_DIR}/openclaw-update"
install -m 0755 "${REPO_DIR}/bin/openclaw-list.sh"   "${BIN_DIR}/openclaw-list"

install -m 0644 "${REPO_DIR}/templates/docker-compose.yml.tmpl" "${SHARE_DIR}/templates/docker-compose.yml.tmpl"

echo "Installed openclaw manager scripts."
echo "Commands:"
echo "  openclaw-new N"
echo "  openclaw-delete N"
echo "  openclaw-update N"
echo "  openclaw-list"
