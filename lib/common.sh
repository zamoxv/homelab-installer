#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONFIG_FILE="$SCRIPT_DIR/config/default.conf"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

SERVER_USER="${SERVER_USER:-$USER}"
if [[ -z "$SERVER_USER" ]]; then
  SERVER_USER="$USER"
fi

MEDIA_GROUP="${MEDIA_GROUP:-media}"
MEDIA_ROOT="${MEDIA_ROOT:-/srv/media}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backups}"
CONFIG_ROOT="${CONFIG_ROOT:-/srv/config}"
RESTORE_ROOT="${RESTORE_ROOT:-/srv/restore}"
LOG_DIR="/var/log/homelab-installer"
STATE_DIR="/var/lib/homelab-installer"
STATE_FILE="$STATE_DIR/state"

ensure_runtime() {
  sudo mkdir -p "$LOG_DIR" "$STATE_DIR"
  sudo touch "$STATE_FILE"
  sudo chown -R "$USER:$USER" "$STATE_DIR" || true

  # apt no-interactivo: resuelve prompts de config (confdef/confold) y desactiva
  # el menú de needrestart. Imprescindible para módulos que corren en segundo
  # plano bajo la barra de progreso (un prompt invisible colgaría la instalación).
  echo 'Dpkg::Options { "--force-confdef"; "--force-confold"; };' \
    | sudo tee /etc/apt/apt.conf.d/99homelab >/dev/null
  if [[ -d /etc/needrestart ]]; then
    sudo mkdir -p /etc/needrestart/conf.d
    echo "\$nrconf{restart} = 'a';" \
      | sudo tee /etc/needrestart/conf.d/99homelab.conf >/dev/null
  fi
}

log() {
  local msg="$1"
  echo "[$(date '+%F %T')] $msg" | sudo tee -a "$LOG_DIR/install.log" >/dev/null
}

mark_done() {
  local module="$1"
  grep -qxF "$module" "$STATE_FILE" 2>/dev/null || echo "$module" >> "$STATE_FILE"
}

is_done() {
  local module="$1"
  grep -qxF "$module" "$STATE_FILE" 2>/dev/null
}

msg() {
  dialog --title "HomeLab Installer" --msgbox "$1" 12 76
}

confirm() {
  dialog --title "Confirmar" --yesno "$1" 12 76
}

input_box() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  dialog --title "$title" --inputbox "$prompt" 10 76 "$default" 3>&1 1>&2 2>&3
}

# --- Plugin System: descubrimiento de módulos ---

# Devuelve el valor de una clave de metadata (HLI-<KEY>) de un módulo.
module_meta() {
  local module="$1" key="$2"
  sed -n "s/^# HLI-${key}:[[:space:]]*//p" "$SCRIPT_DIR/modules/$module.sh" | head -n1
}

# Lista los IDs de los módulos registrados, ordenados por HLI-ORDER.
list_modules() {
  local f id order
  for f in "$SCRIPT_DIR"/modules/*.sh; do
    [[ -f "$f" ]] || continue
    grep -q '^# HLI-MODULE:' "$f" || continue
    id="$(basename "$f" .sh)"
    order="$(module_meta "$id" ORDER)"
    printf '%s\t%s\n' "${order:-999}" "$id"
  done | sort -n | cut -f2
}

run_module() {
  local module="$1"
  local path="$SCRIPT_DIR/modules/$module.sh"

  if [[ ! -x "$path" ]]; then
    msg "Módulo no encontrado o no ejecutable:\n$path"
    return 1
  fi

  log "Iniciando módulo: $module"
  if [[ "$(module_meta "$module" TUI)" == "yes" ]]; then
    # Módulo interactivo (dialog/prompts/smbpasswd): hereda la terminal real
    # para que la TUI se dibuje y capture entradas correctamente.
    bash "$path"
  else
    # Módulo batch: vuelca la salida a la terminal y al log del módulo.
    bash "$path" 2>&1 | sudo tee -a "$LOG_DIR/$module.log"
  fi
  log "Finalizado módulo: $module"
}

# Ejecuta un módulo volcando TODA su salida al log (sin terminal). Lo usa la
# barra de progreso para correr el módulo en segundo plano. Devuelve el código
# de salida del módulo.
run_module_quiet() {
  local module="$1"
  local path="$SCRIPT_DIR/modules/$module.sh"
  [[ -x "$path" ]] || return 1
  log "Iniciando módulo (silencioso): $module"
  bash "$path" 2>&1 | sudo tee -a "$LOG_DIR/$module.log" >/dev/null
}

# --- Detección de hardware (best-effort, solo lectura) ---

os_pretty() {
  ( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -sr)}" )
}

hw_model() {
  local vendor product
  vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
  product="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  echo "$vendor $product" | xargs
}

hw_cpu() {
  lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n1
}

hw_ram() {
  free -h 2>/dev/null | awk '/Mem:/ {print $2}'
}

# Disco físico (ruta completa, ej. /dev/nvme0n1) que contiene la raíz. 'lsblk -s'
# recorre las dependencias en sentido inverso (desde el LV/partición/cripto HACIA
# ABAJO hasta el disco real); subir con PKNAME no alcanza en LVM. '-r' evita los
# caracteres de árbol en el nombre; se toma la primera fila TYPE=disk. Quita la
# notación de subvolumen btrfs (/dev/x[/subvol] -> /dev/x).
_root_disk() {
  local src
  src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
  lsblk -srnpo NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1; exit}'
}

hw_disk() {
  local disk size rota typ
  disk="$(_root_disk)"
  [[ -z "$disk" ]] && { echo "N/D"; return; }
  size="$(lsblk -dno SIZE "$disk" 2>/dev/null | head -n1)"
  rota="$(lsblk -dno ROTA "$disk" 2>/dev/null | head -n1)"
  [[ "$rota" == "0" ]] && typ="SSD" || typ="HDD"
  echo "$disk ${size:-?} ($typ)"
}

# Barra ASCII del uso de la partición raíz.
space_bar() {
  local pct filled i bar=""
  pct="$(df / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  pct="${pct:-0}"
  filled=$(( pct * 20 / 100 ))
  for ((i = 0; i < 20; i++)); do
    [[ $i -lt $filled ]] && bar+="#" || bar+="."
  done
  echo "[$bar] ${pct}%"
}

get_ip() {
  hostname -I | awk '{print $1}'
}

detect_iface() {
  if [[ -n "${NETWORK_IFACE:-}" ]]; then
    echo "$NETWORK_IFACE"
    return
  fi

  ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)' | head -n1
}

service_state() {
  local service="$1"
  # 'systemctl cat' no usa tubería: evita el bug de grep -q cerrando el pipe y
  # disparando SIGPIPE en systemctl, que con 'pipefail' daba falso not-installed.
  if systemctl cat "$service" >/dev/null 2>&1; then
    systemctl is-active "$service" 2>/dev/null || true
  else
    echo "not-installed"
  fi
}

# URL de acceso de un servicio (vacío si no expone una). Fuente única de los
# puertos: la usan tanto el resumen post-instalación como el módulo de estado,
# para no duplicar los puertos en varios lugares.
service_url() {
  local service="$1" ip="${2:-$(get_ip)}"
  case "$service" in
    jellyfin)    echo "http://$ip:8096" ;;
    qbittorrent) echo "http://$ip:8080" ;;
    AdGuardHome) echo "http://$ip:3000" ;;
    smbd)        echo "smb://$ip" ;;
    *)           echo "" ;;
  esac
}

# Restaura componentes (Jellyfin, qBittorrent, Samba) leyendo desde la raíz de
# un sistema de archivos viejo montado en $1. Copia solo lo que existe. Lo usan
# tanto "restaurar desde disco viejo" como la migración asistida.
restore_components_from_root() {
  local root="$1" home
  home="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
  home="${home:-/home/$SERVER_USER}"

  if [[ -d "$root/var/lib/jellyfin" ]]; then
    sudo systemctl stop jellyfin 2>/dev/null || true
    sudo rsync -aHAX "$root/var/lib/jellyfin/" /var/lib/jellyfin/
    sudo chown -R jellyfin:jellyfin /var/lib/jellyfin 2>/dev/null || true
    sudo systemctl start jellyfin 2>/dev/null || true
  fi

  if [[ -d "$root/home/$SERVER_USER/.config/qBittorrent" ]]; then
    sudo systemctl stop qbittorrent 2>/dev/null || true
    mkdir -p "$home/.config/qBittorrent" "$home/.local/share/qBittorrent"
    rsync -aHAX "$root/home/$SERVER_USER/.config/qBittorrent/" "$home/.config/qBittorrent/"
    [[ -d "$root/home/$SERVER_USER/.local/share/qBittorrent" ]] \
      && rsync -aHAX "$root/home/$SERVER_USER/.local/share/qBittorrent/" "$home/.local/share/qBittorrent/"
    sudo systemctl start qbittorrent 2>/dev/null || true
  fi

  if [[ -f "$root/etc/samba/smb.conf" ]]; then
    sudo cp /etc/samba/smb.conf "/etc/samba/smb.conf.backup.$(date +%F-%H%M%S)" 2>/dev/null || true
    sudo cp "$root/etc/samba/smb.conf" /etc/samba/smb.conf
    sudo systemctl restart smbd 2>/dev/null || true
  fi

  # Claves SSH autorizadas: para no volver a correr ssh-copy-id tras migrar.
  if sudo test -f "$root/home/$SERVER_USER/.ssh/authorized_keys"; then
    import_authorized_keys "$root/home/$SERVER_USER/.ssh/authorized_keys"
  fi
}

# Fusiona las claves públicas del archivo $1 al authorized_keys del usuario, sin
# perder las que ya estaban (las deduplica). Solo claves públicas.
import_authorized_keys() {
  local src="$1" home
  home="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
  home="${home:-/home/$SERVER_USER}"
  mkdir -p "$home/.ssh"
  chmod 700 "$home/.ssh"
  { sudo cat "$src" 2>/dev/null; cat "$home/.ssh/authorized_keys" 2>/dev/null; } \
    | sort -u > "$home/.ssh/authorized_keys.new"
  mv "$home/.ssh/authorized_keys.new" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
}

# --- Disco viejo: detección, LVM y montaje en SOLO LECTURA (compartido) ---
# mount_old_disk deja la ruta raíz en OLD_DISK_MNT; el llamador limpia con
# unmount_old_disk (y debería ponerlo en un trap EXIT).
OLD_DISK_MNT=""
OLD_DISK_VG=""

# Disco del sistema en nombre corto (ej. nvme0n1), a EXCLUIR siempre. Reusa
# _root_disk, que resuelve bien sobre LVM; el recorrido PKNAME queda solo como
# red de seguridad por si _root_disk no devolviera nada.
_system_disk() {
  local d src p1 p2
  d="$(_root_disk)"
  [[ -n "$d" ]] && { basename "$d"; return; }
  src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
  p1="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
  [[ -z "$p1" ]] && p1="$(basename "$src")"
  p2="$(lsblk -no PKNAME "/dev/$p1" 2>/dev/null | head -n1 || true)"
  echo "${p2:-$p1}"
}

_vg_uuid_on_disk() {
  sudo pvs --noheadings -o pv_name,vg_uuid 2>/dev/null \
    | awk -v d="/dev/$1" '$1 ~ ("^" d) {print $2; exit}' || true
}

_vg_name_by_uuid() {
  sudo vgs --noheadings -o vg_name,vg_uuid 2>/dev/null \
    | awk -v u="$1" '$2 == u {print $1; exit}' || true
}

mount_old_disk() {
  local sys_disk disk old_uuid old_name mnt lv part n info
  local cand=() menu_args=()
  sys_disk="$(_system_disk)"

  mapfile -t cand < <(lsblk -dno NAME,TYPE 2>/dev/null | awk -v s="$sys_disk" '$2 == "disk" && $1 != s {print $1}')
  if [[ ${#cand[@]} -eq 0 ]]; then
    msg "No se detectó ningún disco aparte del sistema (/dev/$sys_disk).\n\nConecte el disco viejo por USB e intente de nuevo."
    return 1
  fi

  for n in "${cand[@]}"; do
    info="$(lsblk -dno SIZE,MODEL "/dev/$n" 2>/dev/null | head -n1 | xargs || true)"
    menu_args+=("$n" "${info:-disco}")
  done

  disk=$(dialog --clear --title "Disco viejo — detección" \
    --menu "Disco del sistema (EXCLUIDO): /dev/$sys_disk\n\nSeleccione el disco viejo:" \
    16 78 6 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 1

  mnt="$(mktemp -d)"
  OLD_DISK_MNT=""
  OLD_DISK_VG=""

  old_uuid=""
  command -v pvs >/dev/null 2>&1 && old_uuid="$(_vg_uuid_on_disk "$disk")"

  if [[ -n "$old_uuid" ]]; then
    old_name="$(_vg_name_by_uuid "$old_uuid")"
    if [[ "$old_name" != "oldvg" ]]; then
      confirm "Disco viejo con LVM.\n\nVG: ${old_name:-desconocido} (UUID $old_uuid)\n\nSe renombrará a 'oldvg' por UUID para leerlo sin chocar con el VG del sistema. Solo cambia la metadata del disco viejo. ¿Continuar?" \
        || { sudo rmdir "$mnt" 2>/dev/null || true; return 1; }
      sudo vgrename "$old_uuid" oldvg
    fi
    OLD_DISK_VG="oldvg"
    sudo vgchange -ay oldvg >/dev/null
    for lv in $(sudo lvs --noheadings -o lv_path oldvg 2>/dev/null | tr -d ' ' || true); do
      if sudo mount -o ro "$lv" "$mnt" 2>/dev/null; then
        if [[ -e "$mnt/etc/os-release" || -d "$mnt/var/lib" ]]; then OLD_DISK_MNT="$mnt"; break; fi
        sudo umount "$mnt" 2>/dev/null || true
      fi
    done
  else
    for part in $(lsblk -lno NAME "/dev/$disk" 2>/dev/null | tail -n +2 || true); do
      if sudo mount -o ro "/dev/$part" "$mnt" 2>/dev/null; then
        if [[ -e "$mnt/etc/os-release" || -d "$mnt/var/lib" ]]; then OLD_DISK_MNT="$mnt"; break; fi
        sudo umount "$mnt" 2>/dev/null || true
      fi
    done
  fi

  if [[ -z "$OLD_DISK_MNT" ]]; then
    msg "No pude encontrar el sistema de archivos raíz en /dev/$disk.\n\n¿Es el disco correcto?"
    sudo rmdir "$mnt" 2>/dev/null || true
    return 1
  fi
  return 0
}

unmount_old_disk() {
  [[ -n "$OLD_DISK_MNT" ]] && mountpoint -q "$OLD_DISK_MNT" 2>/dev/null && sudo umount "$OLD_DISK_MNT" 2>/dev/null || true
  [[ -n "$OLD_DISK_MNT" && -d "$OLD_DISK_MNT" ]] && sudo rmdir "$OLD_DISK_MNT" 2>/dev/null || true
  [[ -n "$OLD_DISK_VG" ]] && sudo vgchange -an "$OLD_DISK_VG" 2>/dev/null || true
  OLD_DISK_MNT=""
  OLD_DISK_VG=""
}
