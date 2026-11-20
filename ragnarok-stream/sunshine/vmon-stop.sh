#!/usr/bin/env bash
# Sunshine "undo" command: tear the virtual monitor down via Bazzite's helper (re-enables
# the physical outputs) and drop the saved stream size. Never fails the session end.
# Env: VMON_STOP (helper path), STATE_DIR.
set -euo pipefail

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh disable=SC1091
. "$here/lib.sh"

VMON_STOP=${VMON_STOP:-/usr/libexec/sunshine-stop-vmon}

if [ -x "$VMON_STOP" ]; then
    "$VMON_STOP" || log "warning: $VMON_STOP exited non-zero"
else
    log "warning: virtual monitor helper not found: $VMON_STOP"
fi
rm -f "$STATE_DIR/stream-size"
exit 0
