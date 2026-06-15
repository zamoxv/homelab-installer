#!/usr/bin/env bash
# HLI-MODULE: storage
# HLI-DESC: Estructura /srv
# HLI-ORDER: 20
# HLI-DEFAULT: yes
# HLI-TUI: no
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

sudo groupadd -f "$MEDIA_GROUP"
sudo usermod -aG "$MEDIA_GROUP" "$SERVER_USER" || true

sudo mkdir -p "$MEDIA_ROOT"/{peliculas,series,musica,libros,fotos,videos,downloads,transcode}
sudo mkdir -p "$BACKUP_ROOT" "$CONFIG_ROOT" "$RESTORE_ROOT"

sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$MEDIA_ROOT" "$BACKUP_ROOT" "$CONFIG_ROOT" "$RESTORE_ROOT"
sudo chmod -R 2775 "$MEDIA_ROOT" "$BACKUP_ROOT" "$CONFIG_ROOT" "$RESTORE_ROOT"

mark_done storage
