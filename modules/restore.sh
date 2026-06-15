#!/usr/bin/env bash
# HLI-MODULE: restore
# HLI-DESC: Restaurar (backup HLI o disco viejo)
# HLI-ORDER: 80
# HLI-DEFAULT: no
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

qb_home() {
  local h
  h="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
  echo "${h:-/home/$SERVER_USER}"
}

restore_from_backup() {
  local archive work home
  archive=$(input_box "Restaurar" "Ruta del backup .tar.gz:" "$BACKUP_ROOT/") || return
  [[ -f "$archive" ]] || { msg "No se encontró el archivo:\n$archive"; return; }

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  if ! tar -xzf "$archive" -C "$work" 2>/dev/null; then
    msg "No se pudo extraer el backup."
    return
  fi

  # Jellyfin
  if [[ -d "$work/jellyfin/lib" ]]; then
    sudo systemctl stop jellyfin 2>/dev/null || true
    sudo rsync -aHAX "$work/jellyfin/lib/" /var/lib/jellyfin/
    [[ -d "$work/jellyfin/etc" ]] && sudo rsync -aHAX "$work/jellyfin/etc/" /etc/jellyfin/
    sudo chown -R jellyfin:jellyfin /var/lib/jellyfin 2>/dev/null || true
    sudo systemctl start jellyfin 2>/dev/null || true
  fi

  # qBittorrent
  home="$(qb_home)"
  if [[ -d "$work/qbittorrent/config" ]]; then
    sudo systemctl stop qbittorrent 2>/dev/null || true
    mkdir -p "$home/.config/qBittorrent" "$home/.local/share/qBittorrent"
    rsync -aHAX "$work/qbittorrent/config/" "$home/.config/qBittorrent/"
    [[ -d "$work/qbittorrent/share" ]] && rsync -aHAX "$work/qbittorrent/share/" "$home/.local/share/qBittorrent/"
    sudo systemctl start qbittorrent 2>/dev/null || true
  fi

  # Samba
  if [[ -f "$work/samba/smb.conf" ]]; then
    sudo cp /etc/samba/smb.conf "/etc/samba/smb.conf.backup.$(date +%F-%H%M%S)" 2>/dev/null || true
    sudo cp "$work/samba/smb.conf" /etc/samba/smb.conf
    sudo systemctl restart smbd 2>/dev/null || true
  fi

  msg "Restauración desde backup HLI finalizada."
}

restore_from_old_disk() {
  local old_root
  old_root=$(input_box "Restaurar" "Ruta raíz del disco viejo montado:" "/mnt/old") || return
  [[ -d "$old_root" ]] || { msg "No existe la ruta:\n$old_root"; return; }
  restore_components_from_root "$old_root"
  msg "Restauración desde disco viejo finalizada."
}

SRC=$(dialog --clear \
  --backtitle "HomeLab Installer v0.2" \
  --title "Restaurar" \
  --menu "Origen de la restauración:" \
  12 76 4 \
  backup "Desde un backup HLI (.tar.gz)" \
  disco "Desde un disco viejo montado" \
  3>&1 1>&2 2>&3) || exit 0

case "$SRC" in
  backup) restore_from_backup ;;
  disco)  restore_from_old_disk ;;
esac

mark_done restore
