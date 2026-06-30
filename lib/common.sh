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

# Fuerza a AdGuard a escuchar en todas las interfaces (0.0.0.0) tras migrar su
# YAML: el panel web (http.address) y el DNS (dns.bind_hosts). Sin esto, si el
# YAML traía la IP vieja del origen, AdGuard no levanta en la máquina nueva.
# Conserva el puerto del panel. Asume el formato de lista en bloque de AdGuard.
adguard_normalize_bind() {
  local yaml="$1" tmp
  [[ -f "$yaml" ]] || return 0
  # http.address: solo la PRIMERA coincidencia (el panel web), conservando puerto.
  sudo sed -i -E '0,/^[[:space:]]*address:[[:space:]]/ s|^([[:space:]]*address:[[:space:]]*).*:([0-9]+)[[:space:]]*$|\10.0.0.0:\2|' "$yaml"
  # dns.bind_hosts: reemplaza TODA la lista (puede tener varias entradas) por una
  # sola 0.0.0.0, para escuchar en todas las interfaces sin arrastrar la IP vieja.
  tmp="$(mktemp)"
  sudo awk '
    /^[[:space:]]*bind_hosts:[[:space:]]*$/ {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      print; print ind "  - 0.0.0.0"; in_bh = 1; next
    }
    in_bh && /^[[:space:]]*-[[:space:]]/ { next }
    { in_bh = 0; print }
  ' "$yaml" > "$tmp" && sudo cp "$tmp" "$yaml" || true
  rm -f "$tmp"
}

# Libera el puerto 53 que systemd-resolved ocupa por defecto (DNSStubListener),
# imprescindible para que AdGuard (servidor DNS) pueda escuchar en 53. Repunta
# /etc/resolv.conf a los upstreams reales de systemd-resolved para que la máquina
# NO pierda resolución DNS al quitar el stub. Idempotente; no hace nada si
# systemd-resolved no está en uso.
free_dns_port() {
  systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
  sudo mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/99-homelab.conf >/dev/null
  [[ -e /run/systemd/resolve/resolv.conf ]] && sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
  sudo systemctl restart systemd-resolved
}

# Restaura componentes (Jellyfin, qBittorrent, Samba, AdGuard) leyendo desde la
# raíz de un sistema de archivos viejo montado en $1. Copia solo lo que existe.
# Lo usan tanto "restaurar desde disco viejo" como la migración asistida.
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

  # AdGuard Home: toda la config (listas, reglas, clientes, DNS) vive en un solo
  # YAML. Se restaura solo si AdGuard ya está instalado en el destino.
  if [[ -f "$root/opt/AdGuardHome/AdGuardHome.yaml" && -d /opt/AdGuardHome ]]; then
    sudo systemctl stop AdGuardHome 2>/dev/null || true
    sudo cp /opt/AdGuardHome/AdGuardHome.yaml "/opt/AdGuardHome/AdGuardHome.yaml.backup.$(date +%F-%H%M%S)" 2>/dev/null || true
    sudo cp "$root/opt/AdGuardHome/AdGuardHome.yaml" /opt/AdGuardHome/AdGuardHome.yaml
    adguard_normalize_bind /opt/AdGuardHome/AdGuardHome.yaml
    free_dns_port
    sudo systemctl start AdGuardHome 2>/dev/null || true
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

# Reescribe la ruta de media en el smb.conf restaurado cuando ESTA máquina la
# tiene en un punto de montaje distinto al del origen (ej. el origen usa
# /srv/media y acá la media va a /srv/media2). Detecta la raíz del origen leyendo
# el primer share de media (no el de backups) y PREGUNTA el destino real en vez
# de asumirlo. Si el usuario deja el mismo valor, no toca nada.
samba_remap_media() {
  local conf="/etc/samba/smb.conf" old new tmp
  [[ -f "$conf" ]] || return 0
  old="$(sudo sed -n -E 's#^[[:space:]]*path[[:space:]]*=[[:space:]]*(/srv/[^[:space:]]+).*#\1#p' "$conf" 2>/dev/null \
        | grep -vF "$BACKUP_ROOT" | head -n1 || true)"
  old="${old%/*}"   # quita la última carpeta -> raíz de media del origen
  [[ -n "$old" && "$old" != "/srv" ]] || return 0
  new="$(input_box "Migración — ruta de media" "Los recursos de media del origen apuntan a:\n$old\n\n¿En qué punto de montaje está la media en ESTA máquina?" "$old")" || return 0
  [[ -n "$new" && "$new" != "$old" ]] || return 0
  # Reemplazo literal del prefijo (awk index/substr) para no romper con rutas que
  # contengan metacaracteres de regex o el delimitador de sed.
  tmp="$(mktemp)"
  sudo awk -v old="$old/" -v new="$new/" '
    $0 ~ /^[[:space:]]*path[[:space:]]*=/ {
      i = index($0, old)
      if (i > 0) $0 = substr($0, 1, i - 1) new substr($0, i + length(old))
    }
    { print }
  ' "$conf" > "$tmp" && sudo cp "$tmp" "$conf" || true
  rm -f "$tmp"
  sudo systemctl restart smbd 2>/dev/null || true
}

# Asegura acceso SSH sin clave a $1 (user@host). Si falta, ofrece configurarlo
# con ssh-copy-id (genera una clave local si no hay). Devuelve 0 con acceso, 1 si
# el usuario cancela o no se pudo establecer. Lo usan los flujos de migración SSH.
ensure_ssh_access() {
  local target="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" true 2>/dev/null && return 0
  confirm "No hay acceso SSH sin clave a $target.\n\n¿Configurarlo ahora? Se genera una clave local si no existe y se copia al origen (pedirá la contraseña del origen una sola vez)." || return 1
  [[ -f "$HOME/.ssh/id_ed25519.pub" || -f "$HOME/.ssh/id_rsa.pub" ]] \
    || ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
  clear
  echo "Copiando la clave pública a $target."
  echo "Ingrese la contraseña del origen cuando la pida:"
  echo
  ssh-copy-id "$target" || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" true 2>/dev/null
}

# Garantiza que rsync pueda leer archivos de root en el ORIGEN $1 (user@host). Si
# el usuario del origen ya tiene sudo sin contraseña para rsync, no hace nada. Si
# no, ofrece crear un permiso temporal NOPASSWD acotado SOLO a rsync (pide la
# contraseña del origen una vez vía ssh -t) y marca que hay que quitarlo después.
# Deja la ruta remota de rsync en REMOTE_RSYNC. El llamador DEBE poner un trap que
# invoque cleanup_remote_sudo para no dejar el permiso colgado.
HLI_REMOTE_SUDO_TMP=""
REMOTE_RSYNC="rsync"
ensure_remote_sudo() {
  local target="$1" rpath
  local sshc=(-o BatchMode=yes -o ConnectTimeout=5)
  rpath="$(ssh "${sshc[@]}" "$target" 'command -v rsync' 2>/dev/null || true)"
  [[ -n "$rpath" ]] || rpath="rsync"
  REMOTE_RSYNC="$rpath"
  # ¿Ya puede correr rsync con sudo sin contraseña?
  if ssh "${sshc[@]}" "$target" "sudo -n $rpath --version" >/dev/null 2>&1; then
    return 0
  fi
  confirm "El usuario del origen no tiene sudo sin contraseña.\n\nSe necesita para leer las configs protegidas (Jellyfin, AdGuard).\n\n¿Configurar un permiso temporal en el origen ahora? Se pedirá la contraseña del origen una sola vez y se quita automáticamente al terminar." || return 1
  clear
  echo "Configurando permiso temporal (solo rsync) en $target."
  echo "Ingrese la contraseña del origen cuando la pida:"
  echo
  ssh -t "$target" "printf '%s ALL=(ALL) NOPASSWD: %s\n' \"\$(id -un)\" '$rpath' | sudo tee /etc/sudoers.d/99-hli-migrate >/dev/null && sudo chmod 440 /etc/sudoers.d/99-hli-migrate" || return 1
  ssh "${sshc[@]}" "$target" "sudo -n $rpath --version" >/dev/null 2>&1 || return 1
  HLI_REMOTE_SUDO_TMP="$target"
  return 0
}

# Quita el sudoers temporal del origen si ensure_remote_sudo lo creó. Idempotente.
cleanup_remote_sudo() {
  [[ -n "$HLI_REMOTE_SUDO_TMP" ]] || return 0
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$HLI_REMOTE_SUDO_TMP" \
    'sudo rm -f /etc/sudoers.d/99-hli-migrate' 2>/dev/null || true
  HLI_REMOTE_SUDO_TMP=""
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
