#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

sudo apt install -y qbittorrent-nox

sudo mkdir -p "$MEDIA_ROOT/downloads"
sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$MEDIA_ROOT/downloads"
sudo chmod -R 2775 "$MEDIA_ROOT/downloads"

sudo tee /etc/systemd/system/qbittorrent.service > /dev/null <<EOF
[Unit]
Description=qBittorrent-nox service
After=network.target

[Service]
User=$SERVER_USER
Group=$SERVER_USER
Type=simple
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable qbittorrent
sudo systemctl restart qbittorrent || true

mark_done qbittorrent
