#!/usr/bin/env bash
set -euo pipefail

show_dashboard() {
  local ip host kernel os model cpu ram disk_root disk_use jf qb smb ag
  ip="$(get_ip || true)"
  host="$(hostname)"
  kernel="$(uname -r)"
  os="$(os_pretty)"
  model="$(hw_model)"
  cpu="$(hw_cpu)"
  ram="$(hw_ram)"
  disk_root="$(hw_disk)"
  disk_use="$(space_bar)"

  jf="$(service_state jellyfin)"
  qb="$(service_state qbittorrent)"
  smb="$(service_state smbd)"
  ag="$(service_state AdGuardHome)"

  cat > /tmp/homelab-dashboard.txt <<EOF
========================================================
            HomeLab Installer
========================================================

Equipo    : ${model:-N/D}
CPU       : ${cpu:-N/D}
Memoria   : ${ram:-N/D}
Disco     : ${disk_root:-N/D}

Servidor  : $host
Usuario   : $SERVER_USER
Sistema   : $os
Kernel    : $kernel
IP        : ${ip:-sin IP}

Servicios
  Jellyfin      : $jf
  qBittorrent   : $qb
  Samba         : $smb
  AdGuard Home  : $ag

Espacio en /
  $disk_use

Rutas
  Media         : $MEDIA_ROOT
  Backups       : $BACKUP_ROOT
  Logs          : $LOG_DIR
========================================================
EOF

  dialog --title "Dashboard" --textbox /tmp/homelab-dashboard.txt 30 92
}

main_menu() {
  while true; do
    CHOICE=$(dialog --clear \
      --backtitle "HomeLab Installer v0.2" \
      --title "Menú principal" \
      --menu "Seleccione una opción:" \
      22 80 12 \
      1 "Dashboard del servidor" \
      2 "Instalación completa recomendada" \
      3 "Instalación personalizada" \
      4 "Perfil de servidor (energía y mantenimiento)" \
      5 "Configurar Samba + carpetas" \
      6 "Backup de configuración" \
      7 "Restaurar (backup o disco viejo)" \
      8 "Migración asistida (disco viejo automático)" \
      9 "Actualizar servidor" \
      10 "Estado de servicios" \
      11 "Diagnóstico (Health Check)" \
      12 "Salir" \
      3>&1 1>&2 2>&3) || exit 0

    # El brace + '|| true' evita que un Cancelar/No en un submenú (estado != 0)
    # mate el bucle del menú por culpa de 'set -e'.
    { case "$CHOICE" in
      1) show_dashboard ;;
      2) install_full ;;
      3) install_custom ;;
      4) server_profile ;;
      5) run_module storage; run_module samba ;;
      6) run_module backup ;;
      7) run_module restore ;;
      8) run_module migrate ;;
      9) run_module update ;;
      10) run_module status ;;
      11) run_module healthcheck ;;
      12) clear; exit 0 ;;
    esac; } || true
  done
}

# Corre un módulo batch en segundo plano mostrando una barra de progreso.
# La salida va al log; si el módulo falla, avisa con la ruta del log.
run_module_gauge() {
  local module="$1" title="$2" pid rc p
  run_module_quiet "$module" &
  pid=$!
  (
    p=5
    while kill -0 "$pid" 2>/dev/null; do
      echo "$p"
      if (( p < 90 )); then p=$((p + 5)); fi
      sleep 1
    done
    echo 100
  ) | dialog --title "$title" --gauge "Instalando $module..." 8 70 5
  rc=0
  wait "$pid" || rc=$?
  if [[ $rc -ne 0 ]]; then
    msg "El módulo '$module' terminó con errores (código $rc).\n\nRevisá el log:\n$LOG_DIR/$module.log"
  fi
}

install_full() {
  local all=() m i=0 total
  for m in $(list_modules); do
    [[ "$(module_meta "$m" DEFAULT)" == "yes" ]] && all+=("$m")
  done
  total=${#all[@]}

  confirm "Se instalarán $total módulos recomendados:\n\n${all[*]}\n\n¿Continuar?" || return

  for m in "${all[@]}"; do
    i=$((i + 1))
    if [[ "$(module_meta "$m" TUI)" == "yes" ]]; then
      run_module "$m"
    else
      run_module_gauge "$m" "Instalación completa ($i/$total)"
    fi
  done

  run_module status
  msg "Instalación completa finalizada.\n\nJellyfin: http://$(get_ip):8096\nqBittorrent: http://$(get_ip):8080\nAdGuard: http://$(get_ip):3000"
}

install_custom() {
  local args=() m desc state
  for m in $(list_modules); do
    desc="$(module_meta "$m" DESC)"
    [[ "$(module_meta "$m" DEFAULT)" == "yes" ]] && state="ON" || state="OFF"
    args+=("$m" "$desc" "$state")
  done

  SERVICES=$(dialog --clear \
    --backtitle "HomeLab Installer v0.2" \
    --title "Instalación personalizada" \
    --checklist "Seleccione módulos:" \
    22 82 12 \
    "${args[@]}" \
    3>&1 1>&2 2>&3) || return

  for item in $SERVICES; do
    item="${item//\"/}"
    run_module "$item"
  done
}

# ¿Hay algún disco SSD / HDD presente? (ROTA=0 → SSD, 1 → HDD)
has_ssd() { grep -qx 0 <<<"$(lsblk -dno ROTA 2>/dev/null)"; }
has_hdd() { grep -qx 1 <<<"$(lsblk -dno ROTA 2>/dev/null)"; }

# Limita el tamaño del journal en disco (drop-in idempotente).
apply_journald_limit() {
  sudo mkdir -p /etc/systemd/journald.conf.d
  sudo tee /etc/systemd/journald.conf.d/homelab.conf > /dev/null <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
  sudo systemctl restart systemd-journald
}

enable_fstrim() {
  sudo systemctl enable --now fstrim.timer
}

enable_smartd() {
  sudo apt install -y smartmontools
  sudo systemctl enable --now smartmontools 2>/dev/null \
    || sudo systemctl enable --now smartd 2>/dev/null \
    || true
}

server_profile() {
  local choice extras
  choice=$(dialog --clear \
    --backtitle "HomeLab Installer v0.2" \
    --title "Perfil de servidor" \
    --radiolist "Tipo de equipo (determina energía y mantenimiento):" \
    14 76 3 \
    24x7 "24/7 (servidor siempre encendido)" ON \
    escritorio "Escritorio (permite suspensión)" OFF \
    notebook "Notebook (conserva batería)" OFF \
    3>&1 1>&2 2>&3) || return

  case "$choice" in
    24x7)
      run_module power
      run_module wol
      apply_journald_limit
      extras="journald (límite de logs)"
      if has_ssd; then enable_fstrim; extras+="\nfstrim.timer (SSD detectado)"; fi
      if has_hdd; then enable_smartd; extras+="\nsmartd (HDD detectado)"; fi
      msg "Perfil 24/7 aplicado.\n\nEnergía: no suspender, ignorar tapa.\nWOL activado.\n$extras"
      ;;
    escritorio|notebook)
      msg "Perfil '$choice' seleccionado.\n\nNo se fuerza el comportamiento de servidor: se permite la suspensión y no se activa WOL.\n\nSi antes aplicaste el perfil 24/7 y querés revertir la suspensión, desenmascarar los *.target manualmente."
      ;;
  esac
}
