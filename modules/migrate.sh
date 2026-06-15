#!/usr/bin/env bash
# HLI-MODULE: migrate
# HLI-DESC: Migración asistida (disco viejo automático)
# HLI-ORDER: 78
# HLI-DEFAULT: no
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

MNT=""
ACTIVE_VG=""

cleanup_migrate() {
  [[ -n "$MNT" ]] && mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT" 2>/dev/null || true
  [[ -n "$MNT" && -d "$MNT" ]] && sudo rmdir "$MNT" 2>/dev/null || true
  [[ -n "$ACTIVE_VG" ]] && sudo vgchange -an "$ACTIVE_VG" 2>/dev/null || true
}
trap cleanup_migrate EXIT

# Disco físico que contiene la raíz (a EXCLUIR siempre).
system_disk() {
  local src p1 p2
  src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
  p1="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
  [[ -z "$p1" ]] && p1="$(basename "$src")"
  p2="$(lsblk -no PKNAME "/dev/$p1" 2>/dev/null | head -n1 || true)"
  echo "${p2:-$p1}"
}

# UUID del VG cuyo PV está en el disco $1 (vacío si el disco no es LVM).
vg_uuid_on_disk() {
  sudo pvs --noheadings -o pv_name,vg_uuid 2>/dev/null \
    | awk -v d="/dev/$1" '$1 ~ ("^" d) {print $2; exit}' || true
}

vg_name_by_uuid() {
  sudo vgs --noheadings -o vg_name,vg_uuid 2>/dev/null \
    | awk -v u="$1" '$2 == u {print $1; exit}' || true
}

# --- 1. Detección (solo lectura) ---
SYS_DISK="$(system_disk)"

mapfile -t cand < <(lsblk -dno NAME,TYPE 2>/dev/null | awk -v s="$SYS_DISK" '$2 == "disk" && $1 != s {print $1}')

if [[ ${#cand[@]} -eq 0 ]]; then
  msg "No se detectó ningún disco aparte del sistema (/dev/$SYS_DISK).\n\nConectá el disco viejo por USB y reintentá."
  exit 0
fi

menu_args=()
for n in "${cand[@]}"; do
  info="$(lsblk -dno SIZE,MODEL "/dev/$n" 2>/dev/null | head -n1 | xargs || true)"
  menu_args+=("$n" "${info:-disco}")
done

DISK=$(dialog --clear --title "Migración asistida — detección" \
  --menu "Disco del sistema (EXCLUIDO): /dev/$SYS_DISK\n\nElegí el disco viejo a migrar:" \
  16 78 6 \
  "${menu_args[@]}" \
  3>&1 1>&2 2>&3) || exit 0

MNT="$(mktemp -d)"
OLD_ROOT=""

# --- 2. Acceso al disco viejo ---
OLD_UUID=""
command -v pvs >/dev/null 2>&1 && OLD_UUID="$(vg_uuid_on_disk "$DISK")"

if [[ -n "$OLD_UUID" ]]; then
  # Disco con LVM. Renombramos SIEMPRE el VG viejo a un nombre único por UUID
  # ('oldvg'). Dos discos Ubuntu suelen tener ambos un 'ubuntu-vg', y con nombres
  # duplicados LVM rechaza operar por nombre — por eso renombramos por UUID, que
  # nunca es ambiguo. Si ya se llama 'oldvg', no se vuelve a renombrar.
  OLD_NAME="$(vg_name_by_uuid "$OLD_UUID")"

  if [[ "$OLD_NAME" != "oldvg" ]]; then
    confirm "Disco viejo con LVM detectado.\n\nVG viejo : ${OLD_NAME:-desconocido}\nUUID     : $OLD_UUID\n\nSe renombrará a 'oldvg' (por UUID) para leerlo sin chocar con el VG del sistema. Solo cambia la metadata del disco viejo. ¿Continuar?" || exit 0
    sudo vgrename "$OLD_UUID" oldvg
  fi
  ACTIVE_VG="oldvg"

  sudo vgchange -ay oldvg >/dev/null

  for lv in $(sudo lvs --noheadings -o lv_path oldvg 2>/dev/null | tr -d ' ' || true); do
    if sudo mount -o ro "$lv" "$MNT" 2>/dev/null; then
      if [[ -e "$MNT/etc/os-release" || -d "$MNT/var/lib" ]]; then
        OLD_ROOT="$MNT"; break
      fi
      sudo umount "$MNT" 2>/dev/null || true
    fi
  done
else
  # Disco sin LVM: probar sus particiones.
  for part in $(lsblk -lno NAME "/dev/$DISK" 2>/dev/null | tail -n +2 || true); do
    if sudo mount -o ro "/dev/$part" "$MNT" 2>/dev/null; then
      if [[ -e "$MNT/etc/os-release" || -d "$MNT/var/lib" ]]; then
        OLD_ROOT="$MNT"; break
      fi
      sudo umount "$MNT" 2>/dev/null || true
    fi
  done
fi

if [[ -z "$OLD_ROOT" ]]; then
  msg "No pude encontrar el sistema de archivos raíz en /dev/$DISK.\n\n¿Es el disco correcto?"
  exit 0
fi

# --- 3. Restauración ---
confirm "Disco viejo montado en SOLO LECTURA:\n  /dev/$DISK -> $OLD_ROOT\n\nSe restaurará la config de Jellyfin, qBittorrent y Samba (la media NO).\n\n¿Continuar?" || exit 0

restore_components_from_root "$OLD_ROOT"

msg "Migración finalizada.\n\nSe restauró desde /dev/$DISK (montado solo lectura: su contenido no se modificó).\n\nYa podés desconectar el disco viejo."

mark_done migrate
