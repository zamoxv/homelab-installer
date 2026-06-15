#!/usr/bin/env bash
set -euo pipefail

show_dashboard() {
  local ip host kernel disk mem jf qb smb ag
  ip="$(get_ip || true)"
  host="$(hostname)"
  kernel="$(uname -r)"
  disk="$(df -h / | awk 'NR==2 {print $3 " usado / " $2 " total (" $5 ")"}')"
  mem="$(free -h | awk '/Mem:/ {print $3 " usado / " $2 " total"}')"

  jf="$(service_state jellyfin)"
  qb="$(service_state qbittorrent)"
  smb="$(service_state smbd)"
  ag="$(service_state AdGuardHome)"

  cat > /tmp/homelab-dashboard.txt <<EOF
HomeLab Installer v0.2

Servidor : $host
Usuario  : $SERVER_USER
IP       : ${ip:-sin IP}
Kernel   : $kernel

Disco    : $disk
Memoria  : $mem

Servicios:
  Jellyfin      : $jf
  qBittorrent   : $qb
  Samba         : $smb
  AdGuard Home  : $ag

Rutas:
  Media         : $MEDIA_ROOT
  Backups       : $BACKUP_ROOT
  Logs          : $LOG_DIR
EOF

  dialog --title "Dashboard" --textbox /tmp/homelab-dashboard.txt 24 90
}

main_menu() {
  while true; do
    CHOICE=$(dialog --clear \
      --backtitle "HomeLab Installer v0.2" \
      --title "Menú principal" \
      --menu "Seleccione una opción:" \
      20 78 10 \
      1 "Dashboard del servidor" \
      2 "Instalación completa recomendada" \
      3 "Instalación personalizada" \
      4 "Perfil de servidor (energía y mantenimiento)" \
      5 "Configurar Samba + carpetas" \
      6 "Restaurar desde disco antiguo" \
      7 "Estado de servicios" \
      8 "Salir" \
      3>&1 1>&2 2>&3) || exit 0

    case "$CHOICE" in
      1) show_dashboard ;;
      2) install_full ;;
      3) install_custom ;;
      4) server_profile ;;
      5) run_module storage; run_module samba ;;
      6) run_module restore ;;
      7) run_module status ;;
      8) clear; exit 0 ;;
    esac
  done
}

install_full() {
  local list="" m
  for m in $(list_modules); do
    [[ "$(module_meta "$m" DEFAULT)" == "yes" ]] && list+="${list:+ }$m"
  done

  confirm "Se instalarán los módulos recomendados:\n\n$list\n\n¿Continuar?" || return

  for m in $list; do
    run_module "$m"
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
has_ssd() { lsblk -dno ROTA 2>/dev/null | grep -q '^0$'; }
has_hdd() { lsblk -dno ROTA 2>/dev/null | grep -q '^1$'; }

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
