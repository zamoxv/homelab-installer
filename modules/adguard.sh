#!/usr/bin/env bash
# HLI-MODULE: adguard
# HLI-DESC: AdGuard Home
# HLI-ORDER: 70
# HLI-DEFAULT: yes
# HLI-TUI: no
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

if ! systemctl list-unit-files | grep -q '^AdGuardHome'; then
  curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sudo sh -s -- -v
fi

sudo systemctl enable AdGuardHome
sudo systemctl restart AdGuardHome || true

mark_done adguard
