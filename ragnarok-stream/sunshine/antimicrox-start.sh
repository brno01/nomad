#!/usr/bin/env bash
# Sunshine "do" command: start a detached WATCHER (setsid, pid in $STATE_DIR/antimicrox-watch.pid, never more
# than one) that keeps AntiMicroX (Flatpak, hidden, with the Ragnarok profile) applied to the Sunshine pad.
# Every WATCH_POLL (1 s) it reads /proc/bus/input/devices (INPUT_DEVICES) and collects the eventN handlers of
# devices whose name matches SUNSHINE_PAD_PATTERN (default X-?Box 360). Whenever that set changes and is
# non-empty (the pad appeared, or was re-created after a reconnect) it stops our AntiMicroX and starts a fresh
# one with --profile, which then applies to the existing pad. See antimicrox-lib.sh for why.
# Always exits 0; real failures go to LAST_ERRORS via record_error.
#
# CLI flags (src/commandlineutility.cpp of AntiMicroX): --hidden (no main window), --profile <file>,
# --eventgen uinput (the X11 XTest backend does not work on Wayland; uinput is also AntiMicroX's Wayland
# default). Flatpak: --device=all for /dev/uinput and --filesystem=<profile dir>:ro so the sandbox can read it.
# Env: FLATPAK (default flatpak), ANTIMICROX_APP, RO_AMGP (profile), STATE_DIR,
# INPUT_DEVICES, SUNSHINE_PAD_PATTERN, WATCH_POLL.
set -euo pipefail
trap 'exit 0' EXIT

SELF=$(readlink -f "${BASH_SOURCE[0]}")
here=$(dirname "$SELF")
# shellcheck source=lib.sh disable=SC1091
. "$here/lib.sh"
# shellcheck source=antimicrox-lib.sh disable=SC1091
. "$here/antimicrox-lib.sh"

FLATPAK=${FLATPAK:-flatpak}
ANTIMICROX_APP=${ANTIMICROX_APP:-io.github.antimicrox.antimicrox}
WATCH_POLL=${WATCH_POLL:-1}
profile_dir=$(cd "$here/../antimicrox" && pwd)
RO_AMGP=${RO_AMGP:-$profile_dir/ragnarok.amgp}

launch_amx() {
    stop_amx
    setsid "$FLATPAK" run --device=all "--filesystem=$(dirname "$RO_AMGP"):ro" "$ANTIMICROX_APP" \
        --hidden --eventgen uinput --profile "$RO_AMGP" </dev/null >/dev/null 2>&1 &
    echo "$!" >"$AMX_PID" || record_error antimicrox-start.sh "cannot store the AntiMicroX pid"
    disown || true
}

watch() {
    local last="" now
    echo "$$" >"$WATCH_PID"
    while :; do
        now=$(pad_handlers)
        if [ -z "$now" ]; then
            last="" # pad gone: the next appearance restarts even with the same eventN
        elif [ "$now" != "$last" ]; then
            log "Sunshine pad present ($now); (re)starting AntiMicroX"
            launch_amx || record_error antimicrox-start.sh "could not start AntiMicroX"
            last=$now
        fi
        sleep "$WATCH_POLL"
    done
}

start() {
    local pid
    mkdir -p "$STATE_DIR"
    pid=$(cat "$WATCH_PID" 2>/dev/null || true)
    if watcher_alive "$pid"; then
        log "AntiMicroX watcher already running (pid $pid)"
        return 0
    fi
    if ! command -v "$FLATPAK" >/dev/null 2>&1 && [ ! -x "$FLATPAK" ]; then
        record_error antimicrox-start.sh "flatpak not found ($FLATPAK); AntiMicroX not started"
        return 0
    fi
    if [ ! -r "$RO_AMGP" ]; then
        record_error antimicrox-start.sh "profile not found: $RO_AMGP; AntiMicroX not started"
        return 0
    fi
    setsid "$SELF" __watch </dev/null >/dev/null 2>&1 &
    echo "$!" >"$WATCH_PID" || record_error antimicrox-start.sh "cannot store the watcher pid"
    disown || true
}

case "${1:-}" in
__watch) watch ;;
*) start || record_error antimicrox-start.sh "start failed" ;;
esac
exit 0
