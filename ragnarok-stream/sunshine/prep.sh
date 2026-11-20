#!/usr/bin/env bash
# Sunshine "do" command: dim the internal panel to the minimum non-zero level and
# block idle/sleep for the duration of the stream. Always exits 0.
# Env overrides (tests): BUSCTL, SYSTEMD_INHIBIT, BRIGHTNESSCTL, STATE_DIR.
set -euo pipefail
trap 'exit 0' EXIT # a failed helper must never abort the stream

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh disable=SC1091
. "$here/lib.sh"

mkdir -p "$STATE_DIR" 2>/dev/null || log "warning: cannot create $STATE_DIR"

dim() {
    local state=$STATE_DIR/brightness backend display value
    if [ -s "$state" ]; then
        log "brightness already saved; keeping the original value"
        read -r backend display _ <"$state" || true
    else
        if ! read -r backend display value < <(brightness_get); then
            log "warning: no brightness backend worked; leaving brightness alone"
            return 0
        fi
        echo "$backend $display $value" >"$state" || log "warning: cannot save brightness"
    fi
    if ! brightness_set "$backend" "$display" "$MIN_BRIGHTNESS"; then
        log "warning: could not set brightness via $backend"
    fi
}

inhibit() {
    local pidfile=$STATE_DIR/inhibit.pid pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if inhibitor_alive "$pid"; then
        return 0
    fi
    if ! command -v "$SYSTEMD_INHIBIT" >/dev/null 2>&1; then
        log "warning: systemd-inhibit not found; the machine may idle-suspend"
        return 0
    fi
    # setsid from a non-group-leader execs in place, so $! is also the group id undo kills.
    setsid "$SYSTEMD_INHIBIT" --what=idle:sleep --who="$INHIBIT_WHO" --why="Sunshine stream" \
        sleep infinity </dev/null >/dev/null 2>&1 &
    echo "$!" >"$pidfile" || log "warning: cannot store inhibitor PID"
    disown || true
}

dim || log "warning: brightness step failed"
inhibit || log "warning: inhibitor step failed"
exit 0
