#!/usr/bin/env bash
# HLI-MODULE: media-transfer
# HLI-DESC: Transferir media desde un disco viejo (automático)
# HLI-ORDER: 79
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

trap unmount_old_disk EXIT

mount_old_disk || exit 0

# Se asume la misma estructura del HLI: la media del disco viejo en su MEDIA_ROOT.
src_root="$OLD_DISK_MNT$MEDIA_ROOT"
if [[ ! -d "$src_root" ]]; then
  msg "No encontré $MEDIA_ROOT en el disco viejo:\n$src_root\n\n¿La media estaba en otra ruta?"
  exit 0
fi

# Checklist con las carpetas presentes (y su tamaño).
args=()
for d in "$src_root"/*/; do
  [[ -d "$d" ]] || continue
  name="$(basename "$d")"
  size="$(du -sh "$d" 2>/dev/null | cut -f1)"
  args+=("$name" "${size:-?}" ON)
done

if [[ ${#args[@]} -eq 0 ]]; then
  msg "No hay carpetas de media en:\n$src_root"
  exit 0
fi

sel=$(dialog --clear --title "Transferir media" \
  --checklist "Carpetas a copiar desde el disco viejo (tamaño a la derecha):" \
  20 76 12 "${args[@]}" 3>&1 1>&2 2>&3) || exit 0

[[ -z "$sel" ]] && exit 0

confirm "Se copiarán las carpetas seleccionadas a $MEDIA_ROOT.\n\nPuede tardar MUCHO (cientos de GB, según el disco). ¿Continuar?" || exit 0

clear
for folder in $sel; do
  folder="${folder//\"/}"
  echo
  echo "==> Copiando: $folder"
  sudo mkdir -p "$MEDIA_ROOT/$folder"
  sudo rsync -aH --info=progress2 "$src_root/$folder/" "$MEDIA_ROOT/$folder/"
  sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$MEDIA_ROOT/$folder"
  sudo chmod -R 2775 "$MEDIA_ROOT/$folder"
done

msg "Transferencia de media finalizada."
mark_done media-transfer
