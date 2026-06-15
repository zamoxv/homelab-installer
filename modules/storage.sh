#!/usr/bin/env bash
# HLI-MODULE: storage
# HLI-DESC: Estructura /srv y expansión de LVM
# HLI-ORDER: 20
# HLI-DEFAULT: yes
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Ubuntu Server deja el LV de raíz en ~100 GB y el resto del VG sin asignar.
# Si la raíz está sobre LVM y hay espacio libre, ofrecer extender / a todo el
# disco. Idempotente: sin LVM o sin espacio libre, no hace nada.
expand_lvm_root() {
  command -v lvs >/dev/null 2>&1 || return 0

  local root_src lv_path vg free_g
  root_src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
  [[ -n "$root_src" ]] || return 0

  # Buscar el LV cuyo dispositivo resuelve al mismo que la raíz.
  lv_path="$(sudo lvs --noheadings -o lv_path 2>/dev/null | tr -d ' ' | while read -r p; do
    if [[ "$(readlink -f "$p")" == "$(readlink -f "$root_src")" ]]; then
      echo "$p"; break
    fi
  done)"
  [[ -n "$lv_path" ]] || return 0   # la raíz no está sobre LVM

  vg="$(sudo lvs --noheadings -o vg_name "$lv_path" 2>/dev/null | tr -d ' ')"
  free_g="$(sudo vgs --noheadings --nosuffix --units g -o vg_free "$vg" 2>/dev/null | tr -d ' <' | cut -d. -f1)"
  [[ -n "$free_g" && "$free_g" -gt 0 ]] || return 0   # sin espacio libre

  if confirm "Se detectó espacio libre en el LVM.\n\nVG       : $vg\nLibre    : ${free_g} GB\nLV raíz  : $lv_path\n\n¿Extender el sistema de archivos a todo el disco?"; then
    sudo lvextend -l +100%FREE -r "$lv_path"
    msg "Sistema extendido: / ahora usa todo el espacio disponible."
  fi
}

expand_lvm_root

sudo groupadd -f "$MEDIA_GROUP"
sudo usermod -aG "$MEDIA_GROUP" "$SERVER_USER" || true

sudo mkdir -p "$MEDIA_ROOT"/{peliculas,series,musica,libros,fotos,videos,downloads,transcode}
sudo mkdir -p "$BACKUP_ROOT" "$CONFIG_ROOT" "$RESTORE_ROOT"

sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$MEDIA_ROOT" "$BACKUP_ROOT" "$CONFIG_ROOT" "$RESTORE_ROOT"
sudo chmod -R 2775 "$MEDIA_ROOT" "$BACKUP_ROOT" "$CONFIG_ROOT" "$RESTORE_ROOT"

mark_done storage
