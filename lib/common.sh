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

hw_disk() {
  local src disk size rota typ
  # Quita la notación de subvolumen btrfs: /dev/x[/subvol] -> /dev/x
  src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
  # Sube hasta el disco físico que contiene la raíz.
  disk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)"
  [[ -z "$disk" ]] && disk="$(lsblk -ndo NAME "$src" 2>/dev/null | head -n1)"
  [[ -z "$disk" ]] && { echo "N/D"; return; }
  size="$(lsblk -dno SIZE "/dev/$disk" 2>/dev/null | head -n1)"
  rota="$(lsblk -dno ROTA "/dev/$disk" 2>/dev/null | head -n1)"
  [[ "$rota" == "0" ]] && typ="SSD" || typ="HDD"
  echo "/dev/$disk ${size:-?} ($typ)"
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
  if systemctl list-unit-files | grep -q "^$service"; then
    systemctl is-active "$service" 2>/dev/null || true
  else
    echo "not-installed"
  fi
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
}
