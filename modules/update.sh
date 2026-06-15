#!/usr/bin/env bash
# HLI-MODULE: update
# HLI-DESC: Actualizar el servidor (apt + limpieza)
# HLI-ORDER: 5
# HLI-DEFAULT: no
# HLI-TUI: no
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt autoclean -y

mark_done update
