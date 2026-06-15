#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v dialog >/dev/null 2>&1; then
  echo "Instalando dialog..."
  sudo apt update
  sudo apt install -y dialog
fi

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/ui/menu.sh"

ensure_runtime

main_menu
