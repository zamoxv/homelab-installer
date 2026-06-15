#!/usr/bin/env bash
# HLI-MODULE: backup
# HLI-DESC: Backup de configuración y estado
# HLI-ORDER: 82
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

STAMP="$(date +%F-%H%M%S)"
ARCHIVE="$BACKUP_ROOT/backup-$STAMP.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sudo mkdir -p "$BACKUP_ROOT"
mkdir -p "$WORK/jellyfin" "$WORK/qbittorrent" "$WORK/samba" "$WORK/hli" "$WORK/ssh"

# Jellyfin: config y metadata (NO media)
[[ -d /var/lib/jellyfin ]] && sudo rsync -aHAX /var/lib/jellyfin/ "$WORK/jellyfin/lib/" 2>/dev/null || true
[[ -d /etc/jellyfin ]] && sudo rsync -aHAX /etc/jellyfin/ "$WORK/jellyfin/etc/" 2>/dev/null || true

# qBittorrent: config y estado del usuario del servidor
qb_home="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
qb_home="${qb_home:-/home/$SERVER_USER}"
[[ -d "$qb_home/.config/qBittorrent" ]] && rsync -aHAX "$qb_home/.config/qBittorrent/" "$WORK/qbittorrent/config/" 2>/dev/null || true
[[ -d "$qb_home/.local/share/qBittorrent" ]] && rsync -aHAX "$qb_home/.local/share/qBittorrent/" "$WORK/qbittorrent/share/" 2>/dev/null || true

# Samba
[[ -f /etc/samba/smb.conf ]] && sudo cp /etc/samba/smb.conf "$WORK/samba/smb.conf"

# Config del HLI
[[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$WORK/hli/default.conf"

# Claves SSH autorizadas (públicas)
[[ -f "$qb_home/.ssh/authorized_keys" ]] && cp "$qb_home/.ssh/authorized_keys" "$WORK/ssh/authorized_keys" 2>/dev/null || true

# Manifiesto
cat > "$WORK/config.yml" <<EOF
backup:
  fecha: "$STAMP"
  hostname: "$(hostname)"
  usuario: "$SERVER_USER"
  media_root: "$MEDIA_ROOT"
  incluye:
    - jellyfin (config + metadata, sin media)
    - qbittorrent (config + estado)
    - samba (smb.conf)
    - hli (default.conf)
  nota: "La media de $MEDIA_ROOT NO esta incluida; vive en el disco de datos."
EOF

# Empaquetar (el contenido se trajo con sudo: normalizar dueño antes de tar)
sudo chown -R "$USER:$USER" "$WORK"
tar -czf "$WORK/archive.tar.gz" -C "$WORK" jellyfin qbittorrent samba hli ssh config.yml
sudo mv "$WORK/archive.tar.gz" "$ARCHIVE"
sudo chown "$SERVER_USER:$MEDIA_GROUP" "$ARCHIVE" 2>/dev/null || true

size="$(du -h "$ARCHIVE" | cut -f1)"
msg "Backup creado:\n\n$ARCHIVE\n($size)\n\nIncluye config de Jellyfin, qBittorrent, Samba y HLI.\nNO incluye la media de $MEDIA_ROOT."

mark_done backup
