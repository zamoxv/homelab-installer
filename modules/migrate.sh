#!/usr/bin/env bash
# HLI-MODULE: migrate
# HLI-DESC: Restaurar config desde un disco viejo (automático)
# HLI-ORDER: 78
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

trap unmount_old_disk EXIT

mount_old_disk || exit 0

confirm "Disco viejo montado en SOLO LECTURA:\n$OLD_DISK_MNT\n\nSe restaurará la config de Jellyfin, qBittorrent, Samba, AdGuard y las claves SSH autorizadas (la media NO).\n\n¿Continuar?" || exit 0

restore_components_from_root "$OLD_DISK_MNT"

# Si la media en esta máquina vive en otro punto de montaje, reescribe el smb.conf.
samba_remap_media

msg "Config restaurada desde el disco viejo (montado solo lectura: su contenido no se modificó)."
mark_done migrate
