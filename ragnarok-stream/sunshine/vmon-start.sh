#!/usr/bin/env bash
# Sunshine "do" command: create the virtual monitor through Bazzite's helper, but at a
# render size derived from the client (the S22+ is 2340x1080, far more than this iGPU
# should render for a 2D game over Wi-Fi).
#   H' = min(RO_STREAM_HEIGHT (default 720), client height), rounded down to even
#   W' = round(H' * W / H), rounded to an even number
# The helper is run with SUNSHINE_CLIENT_WIDTH/HEIGHT overridden to W' x H'; FPS passes through.
# W' H' is saved in $STATE_DIR/stream-size for ro-resolution.sh.
#
# Unlike prep.sh this one is ALLOWED to fail: without the virtual monitor the stream would
# capture the physical panel (dimmed to ~0 by prep.sh), so aborting the session is better
# than streaming a black screen. The helper's exit status is propagated.
# Sunshine only runs "undo" for prep-cmds that SUCCEEDED, never for the one that failed, and
# Bazzite's helper can disable the physical monitors and then fail; so on failure this script
# calls the stop helper itself (best-effort) before exiting, and does not exec the helper.
# Env: VMON_START, VMON_STOP (helper paths), RO_STREAM_HEIGHT, STATE_DIR,
#      SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS.
set -euo pipefail

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh disable=SC1091
. "$here/lib.sh"

VMON_START=${VMON_START:-/usr/libexec/sunshine-start-vmon}
VMON_STOP=${VMON_STOP:-/usr/libexec/sunshine-stop-vmon}

cw=${SUNSHINE_CLIENT_WIDTH:-1920}
ch=${SUNSHINE_CLIENT_HEIGHT:-1080}
if ! _is_num "$cw" || ! _is_num "$ch" || [ "$cw" -eq 0 ] || [ "$ch" -eq 0 ]; then
    log "warning: invalid client size ${cw}x${ch}; assuming 1920x1080"
    cw=1920
    ch=1080
fi
want=${RO_STREAM_HEIGHT:-720}
if ! _is_num "$want" || [ "$want" -eq 0 ]; then want=720; fi
h=$want
[ "$ch" -lt "$h" ] && h=$ch
h=$((h / 2 * 2)) # even height too (481 -> 480)
[ "$h" -ge 2 ] || h=2
# nearest even width: floor((h*cw/ch + 1) / 2) * 2
# shellcheck disable=SC2017 # deliberate: floor((h*cw/ch + 1) / 2) * 2
w=$(((h * cw + ch) / (2 * ch) * 2))
[ "$w" -ge 2 ] || w=2

mkdir -p "$STATE_DIR"
echo "$w $h" >"$STATE_DIR/stream-size"
log "client ${cw}x${ch} -> virtual monitor ${w}x${h}"

cleanup_failed() {
    log "error: virtual monitor failed (exit $1); cleaning up"
    if [ -x "$VMON_STOP" ]; then "$VMON_STOP" || log "warning: $VMON_STOP exited non-zero"; fi
    rm -f "$STATE_DIR/stream-size"
}

if [ ! -x "$VMON_START" ]; then
    log "error: virtual monitor helper not found: $VMON_START"
    cleanup_failed 1
    exit 1
fi
rc=0
SUNSHINE_CLIENT_WIDTH=$w SUNSHINE_CLIENT_HEIGHT=$h "$VMON_START" || rc=$?
if [ "$rc" -ne 0 ]; then
    cleanup_failed "$rc"
    exit "$rc"
fi
exit 0
