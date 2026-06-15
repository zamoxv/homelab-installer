#!/usr/bin/env bash
# HLI-MODULE: samba
# HLI-DESC: Samba + carpetas compartidas
# HLI-ORDER: 40
# HLI-DEFAULT: yes
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

sudo apt install -y samba

FOLDERS=$(dialog --clear \
  --backtitle "HomeLab Installer" \
  --title "Carpetas SMB" \
  --checklist "Seleccione carpetas a compartir:" \
  22 82 12 \
  peliculas "Películas" ON \
  series "Series" ON \
  musica "Música" ON \
  libros "Libros" ON \
  fotos "Fotos" ON \
  videos "Videos" ON \
  downloads "Descargas qBittorrent" ON \
  backups "Backups" ON \
  3>&1 1>&2 2>&3) || exit 0

sudo cp /etc/samba/smb.conf "/etc/samba/smb.conf.backup.$(date +%F-%H%M%S)"

sudo sed -i '/### HOMELAB-INSTALLER START/,/### HOMELAB-INSTALLER END/d' /etc/samba/smb.conf

{
  echo ""
  echo "### HOMELAB-INSTALLER START"
  for folder in $FOLDERS; do
    folder="${folder//\"/}"

    if [[ "$folder" == "backups" ]]; then
      path="$BACKUP_ROOT"
    else
      path="$MEDIA_ROOT/$folder"
    fi

    sudo mkdir -p "$path"
    sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$path"
    sudo chmod -R 2775 "$path"

    cat <<EOF

[$folder]
   path = $path
   browseable = yes
   read only = no
   guest ok = no
   valid users = $SERVER_USER
   force group = $MEDIA_GROUP
   create mask = 0664
   directory mask = 2775
EOF
  done
  echo "### HOMELAB-INSTALLER END"
} | sudo tee -a /etc/samba/smb.conf >/dev/null

sudo smbpasswd -a "$SERVER_USER" || true
sudo systemctl enable smbd
sudo systemctl restart smbd

mark_done samba
