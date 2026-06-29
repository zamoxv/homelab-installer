#!/usr/bin/env bash
# HLI-MODULE: media-transfer-ssh
# HLI-DESC: Copiar media desde una máquina encendida (por SSH)
# HLI-ORDER: 84
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Copia la media de un servidor viejo ENCENDIDO por SSH. rsync es incremental:
# la primera corrida trae el grueso con el origen en uso, y una segunda corrida
# justo antes del cutover trae solo lo que cambió (downtime mínimo).

host="$(input_box "Media por SSH" "IP o host del origen (encendido):" "")" || exit 0
[[ -n "$host" ]] || { msg "Falta el host de origen."; exit 0; }

ruser="$(input_box "Media por SSH" "Usuario SSH en el origen:" "$SERVER_USER")" || exit 0
[[ -n "$ruser" ]] || { msg "Falta el usuario."; exit 0; }

target="$ruser@$host"
ensure_ssh_access "$target" || { msg "No se pudo establecer acceso SSH a $target."; exit 0; }

src="$(input_box "Media por SSH" "Ruta de la media en el ORIGEN:" "$MEDIA_ROOT")" || exit 0
[[ -n "$src" ]] || exit 0

dst="$(input_box "Media por SSH" "Ruta de la media en ESTA máquina (destino):" "$MEDIA_ROOT")" || exit 0
[[ -n "$dst" ]] || exit 0

mkdir -p "$dst" 2>/dev/null || sudo mkdir -p "$dst"
if ! mountpoint -q "$dst" 2>/dev/null; then
  confirm "AVISO: $dst no es un punto de montaje.\n\nLa media iría al disco del sistema, no a un disco de datos dedicado.\n\n¿Continuar de todas formas?" || exit 0
fi

confirm "Se copiará la media:\n\n$target:$src/  ->  $dst/\n\nrsync es incremental: vuelva a ejecutar este módulo antes del cutover para traer solo lo nuevo. El origen no se modifica.\n\n¿Continuar?" || exit 0

clear
echo "Copiando media desde $target:$src/ hacia $dst/"
echo "(rsync incremental — puede re-ejecutarse antes del cutover)"
echo
rsync -aHAX --info=progress2 --partial -e ssh "$target:$src/" "$dst/" || {
  msg "rsync terminó con errores. Revise la conexión o los permisos en el origen."
  exit 1
}

# Ajusta la propiedad al usuario/grupo de esta máquina (los UID pueden diferir
# entre máquinas). Los permisos de archivo los conserva rsync (-a) del origen.
sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$dst" 2>/dev/null || true

msg "Media copiada desde $target.\n\nrsync es incremental: vuelva a ejecutar este módulo justo antes del cutover para sincronizar lo último."

mark_done media-transfer-ssh
