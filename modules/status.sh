#!/usr/bin/env bash
# HLI-MODULE: status
# HLI-DESC: Ver estado de servicios
# HLI-ORDER: 90
# HLI-DEFAULT: no
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

{
  echo "== Sistema =="
  hostnamectl || true
  echo
  echo "== IP =="
  hostname -I || true
  echo
  echo "== Servicios =="
  for s in jellyfin qbittorrent smbd AdGuardHome wol.service; do
    printf "%-16s %s\n" "$s" "$(service_state "$s")"
  done
  echo
  echo "== Disco =="
  df -h
  echo
  echo "== /srv =="
  sudo du -sh /srv/* 2>/dev/null || true
} > /tmp/homelab-status.txt

dialog --title "Estado del servidor" --textbox /tmp/homelab-status.txt 28 100 || cat /tmp/homelab-status.txt

mark_done status
