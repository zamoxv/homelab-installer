#!/usr/bin/env bash
# HLI-MODULE: jellyfin
# HLI-DESC: Servidor multimedia Jellyfin
# HLI-ORDER: 50
# HLI-DEFAULT: yes
# HLI-TUI: no
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

if ! command -v jellyfin >/dev/null 2>&1; then
  curl https://repo.jellyfin.org/install-debuntu.sh | sudo bash
fi

sudo mkdir -p "$MEDIA_ROOT/transcode"

if id jellyfin >/dev/null 2>&1; then
  sudo usermod -aG "$MEDIA_GROUP" jellyfin || true
  sudo chown -R jellyfin:"$MEDIA_GROUP" "$MEDIA_ROOT/transcode" || true
  sudo chmod -R 2775 "$MEDIA_ROOT/transcode" || true
fi

sudo systemctl enable jellyfin
sudo systemctl restart jellyfin || true

mark_done jellyfin
