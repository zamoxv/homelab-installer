#!/usr/bin/env bash
# HLI-MODULE: status
# HLI-DESC: Ver estado de servicios
# HLI-ORDER: 90
# HLI-DEFAULT: no
# HLI-TIPO: tool
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
  ip="$(get_ip)"
  for s in jellyfin qbittorrent smbd AdGuardHome wol.service; do
    state="$(service_state "$s")"
    url=""
    [[ "$state" == "active" ]] && url="$(service_url "$s" "$ip")"
    printf "%-16s %-14s %s\n" "$s" "$state" "$url"
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
