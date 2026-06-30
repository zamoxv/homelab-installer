#!/usr/bin/env bash
# HLI-MODULE: samba
# HLI-DESC: Samba + carpetas compartidas
# HLI-ORDER: 40
# HLI-DEFAULT: yes
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

sudo apt install -y samba

sudo smbpasswd -a "$SERVER_USER" || true
sudo systemctl enable smbd

# Un recurso por disco de media (/srv/media, /srv/media2, ...) + backups.
samba_write_shares

msg "Samba configurado: un recurso por disco de media (media, media2, ...) + backups.\n\nUsuario: $SERVER_USER"

mark_done samba
