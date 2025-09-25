#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/env.sh"

log "[01] Creating darksite tree..."
DARK="$DARKSITE_DIR"               # from env.sh, e.g., $PWD/darksite
rm -rf "$DARK"
mkdir -p "$DARK"/{opt,etc,usr/local/bin,seeds,profiles/{master,slave}}
install -d "$DARK/opt/unityserver" "$DARK/opt/firecracker" "$DARK/opt/observability"
install -d "$DARK/etc/wireguard" "$DARK/etc/salt/master.d" "$DARK/etc/salt/minion.d"
log "[01] darksite: $DARK"
