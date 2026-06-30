#!/usr/bin/env bash
# HLI-MODULE: migrate-ssh
# HLI-DESC: Migrar config desde una máquina encendida (por SSH)
# HLI-ORDER: 83
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Toma la config de un servidor viejo TODAVÍA ENCENDIDO, por SSH, sin sacarle el
# disco ni apagarlo. Trae los paths a una raíz temporal con forma de filesystem
# y reusa restore_components_from_root (el mismo motor que la migración por
# disco). La media NO se copia acá; es un paso aparte.

# --- Datos del origen ---
host="$(input_box "Migración por SSH" "IP o host de la máquina de origen (la vieja, encendida):" "")" || exit 0
[[ -n "$host" ]] || { msg "Falta el host de origen."; exit 0; }

ruser="$(input_box "Migración por SSH" "Usuario SSH en el origen:" "$SERVER_USER")" || exit 0
[[ -n "$ruser" ]] || { msg "Falta el usuario."; exit 0; }

target="$ruser@$host"

# --- 1) Acceso SSH sin clave; si falta, se resuelve con ssh-copy-id ---
ensure_ssh_access "$target" || { msg "No se pudo establecer acceso SSH a $target."; exit 0; }

# --- 2) sudo en el origen para leer configs de root (Jellyfin, AdGuard). Si no
#        hay sudo sin contraseña, ensure_remote_sudo ofrece configurarlo temporal
#        en el origen; el trap limpia tanto el sudoers remoto como la raíz temp. ---
ROOT=""
trap 'cleanup_remote_sudo; [[ -n "$ROOT" ]] && rm -rf "$ROOT"' EXIT

RSYNC_PATH=()
if ensure_remote_sudo "$target"; then
  RSYNC_PATH=(--rsync-path="sudo $REMOTE_RSYNC")
else
  confirm "No se pudo configurar sudo en el origen.\n\nSe migrará solo lo accesible sin root (Samba, qBittorrent, claves SSH); Jellyfin y AdGuard se saltan.\n\n¿Continuar igual?" || exit 0
fi

# --- 3) Traer los paths a una raíz temporal con forma de filesystem ---
remote_home="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" 'echo "$HOME"' 2>/dev/null || true)"
remote_home="${remote_home:-/home/$ruser}"

confirm "Se migrará la config de $target a esta máquina:\n\nJellyfin, qBittorrent, Samba, AdGuard y claves SSH autorizadas.\n\nLa MEDIA no se copia acá (es un paso aparte). El origen no se modifica. ¿Continuar?" || exit 0

ROOT="$(mktemp -d)"

# El destino dentro de ROOT usa el usuario LOCAL ($SERVER_USER), porque es lo que
# restore_components_from_root espera; el origen puede tener otro home.
mkdir -p "$ROOT/var/lib" "$ROOT/etc/samba" "$ROOT/etc/jellyfin" \
  "$ROOT/opt/AdGuardHome" "$ROOT/home/$SERVER_USER/.config" \
  "$ROOT/home/$SERVER_USER/.local/share" "$ROOT/home/$SERVER_USER/.ssh"

# Configs de root (usan sudo remoto si está disponible).
rsync -aHAX "${RSYNC_PATH[@]}" -e ssh "$target:/var/lib/jellyfin/" "$ROOT/var/lib/jellyfin/" 2>/dev/null || true
rsync -aHAX "${RSYNC_PATH[@]}" -e ssh "$target:/etc/jellyfin/" "$ROOT/etc/jellyfin/" 2>/dev/null || true
rsync -aHAX "${RSYNC_PATH[@]}" -e ssh "$target:/etc/samba/smb.conf" "$ROOT/etc/samba/" 2>/dev/null || true
rsync -aHAX "${RSYNC_PATH[@]}" -e ssh "$target:/opt/AdGuardHome/AdGuardHome.yaml" "$ROOT/opt/AdGuardHome/" 2>/dev/null || true

# Configs del usuario (sin sudo).
rsync -aHAX -e ssh "$target:$remote_home/.config/qBittorrent/" "$ROOT/home/$SERVER_USER/.config/qBittorrent/" 2>/dev/null || true
rsync -aHAX -e ssh "$target:$remote_home/.local/share/qBittorrent/" "$ROOT/home/$SERVER_USER/.local/share/qBittorrent/" 2>/dev/null || true
rsync -aHAX -e ssh "$target:$remote_home/.ssh/authorized_keys" "$ROOT/home/$SERVER_USER/.ssh/" 2>/dev/null || true

# --- 4) Aplicar con el mismo motor de la migración por disco ---
restore_components_from_root "$ROOT"

# Si la media en esta máquina vive en otro punto de montaje, reescribe el smb.conf.
samba_remap_media

msg "Migración por SSH finalizada desde $target.\n\nConfig de Jellyfin, qBittorrent, Samba y AdGuard aplicada.\nLa media se copia por separado."

mark_done migrate-ssh
