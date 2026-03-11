#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="diligentapple"
REPO_NAME="OpenClaw-Mesh-Manager"
BRANCH="main"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${BRANCH}.tar.gz"
curl -fsSL "$URL" -o "${TMP}/repo.tgz"
tar -xzf "${TMP}/repo.tgz" -C "$TMP"

DIR="${TMP}/${REPO_NAME}-${BRANCH}"
cd "$DIR"
bash install.sh
