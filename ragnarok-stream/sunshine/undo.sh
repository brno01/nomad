#!/usr/bin/env bash
# Sunshine "undo" command: restore brightness, release the idle/sleep inhibitor.
# Always exits 0. Env overrides (tests): BUSCTL, SYSTEMD_INHIBIT, BRIGHTNESSCTL, STATE_DIR.
set -euo pipefail
trap 'exit 0' EXIT

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh disable=SC1091
. "$here/lib.sh"

restore() {
    local state=$STATE_DIR/brightness backend display value
    [ -s "$state" ] || return 0
    if read -r backend display value <"$state" && _is_num "$value"; then
        if [ "$backend" = plasma6 ]; then display=$(p6_resolve_display "$display"); fi
        brightness_set "$backend" "$display" "$value" || record_error undo.sh "could not restore brightness via $backend (value $value)"
    else
        record_error undo.sh "unreadable brightness state; dropped it"
    fi
    rm -f "$state"
}

release() {
    local pidfile=$STATE_DIR/inhibit.pid pid
    [ -e "$pidfile" ] || return 0
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if inhibitor_alive "$pid"; then
        # the whole group: real systemd-inhibit keeps the lock while its child lives
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
}

restore || log "warning: brightness restore failed"
release || log "warning: inhibitor release failed"
exit 0
