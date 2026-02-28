#!/usr/bin/env bash
set -euo pipefail

REPO="Arun-Apex/pisignage-player-tools"
TAG="v1.0.0"

SERVER_URL="${1:-https://digiddpm.com}"
MODE="${2:-}"

curl -fsSL "https://raw.githubusercontent.com/${REPO}/${TAG}/scripts/pisignage-golden-setup.sh" \
  | sudo bash -s -- --server "${SERVER_URL}" ${MODE}