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
