#!/usr/bin/env bash
# HLI-MODULE: base
# HLI-DESC: Paquetes base y utilidades
# HLI-ORDER: 10
# HLI-DEFAULT: yes
# HLI-TUI: no
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

sudo apt update
sudo apt upgrade -y

sudo apt install -y \
  curl wget git nano vim htop btop rsync unzip dialog \
  ethtool smartmontools lm-sensors ca-certificates gnupg \
  ufw net-tools lsof ncdu

sudo mkdir -p "$BACKUP_ROOT" "$CONFIG_ROOT" "$RESTORE_ROOT"

mark_done base
