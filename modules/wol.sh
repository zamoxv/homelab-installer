#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

IFACE="$(detect_iface || true)"

if [[ -z "$IFACE" ]]; then
  IFACE=$(input_box "Wake-on-LAN" "No se pudo detectar interfaz. Escriba la interfaz:" "enp0s25")
fi

sudo apt install -y ethtool

sudo tee /etc/systemd/system/wol.service > /dev/null <<EOF
[Unit]
Description=Enable Wake on LAN
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s $IFACE wol g

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable wol.service
sudo systemctl start wol.service || true

mark_done wol
