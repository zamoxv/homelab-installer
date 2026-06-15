#!/usr/bin/env bash
# HLI-MODULE: restore
# HLI-DESC: Restaurar desde disco antiguo
# HLI-ORDER: 80
# HLI-DEFAULT: no
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

OLD_ROOT=$(input_box "Restaurar" "Ruta raíz del disco viejo montado:" "/media/$USER/ubuntu-root")

OPTIONS=$(dialog --clear \
  --backtitle "HomeLab Installer v0.2" \
  --title "Restaurar" \
  --checklist "Seleccione qué restaurar:" \
  18 82 8 \
  jellyfin "Restaurar /var/lib/jellyfin" ON \
  qbittorrent "Restaurar configuración de qBittorrent" ON \
  3>&1 1>&2 2>&3) || exit 0

for opt in $OPTIONS; do
  opt="${opt//\"/}"
  case "$opt" in
    jellyfin)
      sudo systemctl stop jellyfin || true
      if [[ -d "$OLD_ROOT/var/lib/jellyfin" ]]; then
        sudo rsync -aHAX "$OLD_ROOT/var/lib/jellyfin/" /var/lib/jellyfin/
        sudo chown -R jellyfin:jellyfin /var/lib/jellyfin
      else
        msg "No se encontró $OLD_ROOT/var/lib/jellyfin"
      fi
      sudo systemctl start jellyfin || true
      ;;
    qbittorrent)
      sudo systemctl stop qbittorrent || true
      mkdir -p "$HOME/.config" "$HOME/.local/share"
      if [[ -d "$OLD_ROOT/home/$SERVER_USER/.config/qBittorrent" ]]; then
        rsync -aHAX "$OLD_ROOT/home/$SERVER_USER/.config/qBittorrent/" "$HOME/.config/qBittorrent/"
      fi
      if [[ -d "$OLD_ROOT/home/$SERVER_USER/.local/share/qBittorrent" ]]; then
        mkdir -p "$HOME/.local/share/qBittorrent"
        rsync -aHAX "$OLD_ROOT/home/$SERVER_USER/.local/share/qBittorrent/" "$HOME/.local/share/qBittorrent/"
      fi
      sudo systemctl start qbittorrent || true
      ;;
  esac
done

mark_done restore
msg "Restauración finalizada."
