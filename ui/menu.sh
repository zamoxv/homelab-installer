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
      4 "Configurar Samba + carpetas" \
      5 "Restaurar desde disco antiguo" \
      6 "Estado de servicios" \
      7 "Salir" \
      3>&1 1>&2 2>&3) || exit 0

    case "$CHOICE" in
      1) show_dashboard ;;
      2) install_full ;;
      3) install_custom ;;
      4) run_module storage; run_module samba ;;
      5) run_module restore ;;
      6) run_module status ;;
      7) clear; exit 0 ;;
    esac
  done
}

install_full() {
  confirm "Se instalará base, almacenamiento, WOL, Samba, Jellyfin, qBittorrent y AdGuard Home.\n\n¿Continuar?" || return

  for m in $FULL_INSTALL_MODULES; do
    run_module "$m"
  done

  run_module status
  msg "Instalación completa finalizada.\n\nJellyfin: http://$(get_ip):8096\nqBittorrent: http://$(get_ip):8080\nAdGuard: http://$(get_ip):3000"
}

install_custom() {
  SERVICES=$(dialog --clear \
    --backtitle "HomeLab Installer v0.2" \
    --title "Instalación personalizada" \
    --checklist "Seleccione módulos:" \
    22 82 12 \
    base "Paquetes base y utilidades" ON \
    storage "Estructura /srv" ON \
    wol "Wake-on-LAN" ON \
    samba "Samba + carpetas compartidas" ON \
    jellyfin "Servidor multimedia Jellyfin" ON \
    qbittorrent "qBittorrent-nox como servicio" ON \
    adguard "AdGuard Home" ON \
    status "Ver estado" OFF \
    3>&1 1>&2 2>&3) || return

  for item in $SERVICES; do
    item="${item//\"/}"
    run_module "$item"
  done
}
