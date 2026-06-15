#!/usr/bin/env bash
# HLI-MODULE: restore
# HLI-DESC: Restaurar desde un backup (.tar.gz)
# HLI-ORDER: 80
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

archive=$(input_box "Restaurar" "Ruta del backup .tar.gz:" "$BACKUP_ROOT/") || exit 0
[[ -f "$archive" ]] || { msg "No se encontró el archivo:\n$archive"; exit 0; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! tar -xzf "$archive" -C "$work" 2>/dev/null; then
  msg "No se pudo extraer el backup."
  exit 0
fi

home="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
home="${home:-/home/$SERVER_USER}"

# Jellyfin
if [[ -d "$work/jellyfin/lib" ]]; then
  sudo systemctl stop jellyfin 2>/dev/null || true
  sudo rsync -aHAX "$work/jellyfin/lib/" /var/lib/jellyfin/
  [[ -d "$work/jellyfin/etc" ]] && sudo rsync -aHAX "$work/jellyfin/etc/" /etc/jellyfin/
  sudo chown -R jellyfin:jellyfin /var/lib/jellyfin 2>/dev/null || true
  sudo systemctl start jellyfin 2>/dev/null || true
fi

# qBittorrent
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

# Claves SSH autorizadas
[[ -f "$work/ssh/authorized_keys" ]] && import_authorized_keys "$work/ssh/authorized_keys"

msg "Restauración desde backup finalizada."
mark_done restore
