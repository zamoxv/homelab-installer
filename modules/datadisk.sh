#!/usr/bin/env bash
# HLI-MODULE: datadisk
# HLI-DESC: Configurar disco de datos permanente
# HLI-ORDER: 22
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

sys_disk="$(_system_disk)"

# Candidatos: particiones/discos que NO son del sistema.
mapfile -t lines < <(lsblk -rpno NAME,TYPE,SIZE 2>/dev/null | awk -v sd="/dev/$sys_disk" '
  ($2 == "part" || $2 == "disk") && index($1, sd) != 1 { print $1 "\t" $3 }')

if [[ ${#lines[@]} -eq 0 ]]; then
  msg "No se detectó ningún disco/partición aparte del sistema (/dev/$sys_disk).\n\nConectá el disco y reintentá."
  exit 0
fi

menu_args=()
for l in "${lines[@]}"; do
  dev="$(echo "$l" | cut -f1)"
  size="$(echo "$l" | cut -f2)"
  fs="$(lsblk -rpno FSTYPE "$dev" 2>/dev/null | head -n1)"
  menu_args+=("$dev" "$size — ${fs:-sin-fs}")
done

DEV=$(dialog --clear --title "Disco de datos" \
  --menu "Disco del sistema (EXCLUIDO): /dev/$sys_disk\n\nElegí la partición/disco para los datos:" \
  18 78 8 "${menu_args[@]}" 3>&1 1>&2 2>&3) || exit 0

fstype="$(lsblk -rpno FSTYPE "$DEV" 2>/dev/null | head -n1)"

if [[ -z "$fstype" ]]; then
  action="formatear"
else
  action=$(dialog --clear --title "Disco de datos" \
    --menu "$DEV ya tiene un sistema de archivos ($fstype).\n\n¿Qué hacés?" \
    14 70 3 \
    usar "Usar el contenido existente (no borra)" \
    formatear "Formatear en ext4 (BORRA TODO)" \
    3>&1 1>&2 2>&3) || exit 0
fi

if [[ "$action" == "formatear" ]]; then
  confirm "Se va a FORMATEAR $DEV en ext4.\n\n⚠️ SE BORRA TODO su contenido. ¿Continuar?" || exit 0
  confirm "ÚLTIMA confirmación: formatear $DEV y borrar todo.\n\n¿Seguro?" || exit 0
  sudo umount "$DEV" 2>/dev/null || true
  sudo mkfs.ext4 -F "$DEV"
fi

# Punto de montaje por defecto inteligente: si MEDIA_ROOT ya está ocupado
# (montado o con datos), sugerir el primer /srv/mediaN libre (media2, media3...).
default_mp="$MEDIA_ROOT"
if mountpoint -q "$MEDIA_ROOT" 2>/dev/null || [[ -n "$(ls -A "$MEDIA_ROOT" 2>/dev/null)" ]]; then
  n=2
  while mountpoint -q "${MEDIA_ROOT}${n}" 2>/dev/null || [[ -n "$(ls -A "${MEDIA_ROOT}${n}" 2>/dev/null)" ]]; do
    n=$((n + 1))
  done
  default_mp="${MEDIA_ROOT}${n}"
fi

MP=$(input_box "Disco de datos" "Punto de montaje:" "$default_mp") || exit 0

if [[ -d "$MP" && -n "$(ls -A "$MP" 2>/dev/null)" ]]; then
  confirm "OJO: $MP ya tiene contenido.\n\nAl montar el disco ahí, ese contenido queda OCULTO (no se borra, pero no se ve hasta desmontar el disco).\n\n¿Continuar igual?" || exit 0
fi

UUID="$(sudo blkid -s UUID -o value "$DEV" 2>/dev/null)"
[[ -n "$UUID" ]] || { msg "No pude obtener el UUID de $DEV."; exit 0; }

sudo mkdir -p "$MP"

# /etc/fstab por UUID + nofail. Se quita cualquier entrada previa del mismo UUID
# para que sea idempotente (re-ejecutar no duplica líneas).
sudo sed -i "\#^UUID=$UUID #d" /etc/fstab 2>/dev/null || true
echo "UUID=$UUID $MP ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null

sudo systemctl daemon-reload 2>/dev/null || true
sudo mount "$MP" 2>/dev/null || sudo mount -a

sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$MP"
sudo chmod -R 2775 "$MP"

msg "Disco de datos configurado.\n\n$DEV → $MP\nEn /etc/fstab por UUID, con 'nofail' (el server arranca aunque el disco no esté).\nSe monta solo en cada arranque."

mark_done datadisk
