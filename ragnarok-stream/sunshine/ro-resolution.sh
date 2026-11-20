#!/usr/bin/env bash
# Usage: ro-resolution.sh set | restore
#
# set:     back up the display keys of the RO client's OptionInfo.lua (once, into $RO_BACKUP_DIR,
#          which is persistent so a reboot mid-stream can't strand the local game at the stream
#          size; never next to the game files) plus a byte-for-byte copy (optioninfo.orig.lua) for
#          manual recovery, and force fullscreen at the stream size saved by vmon-start.sh
#          ($STATE_DIR/stream-size): WIDTH, HEIGHT, OLD_WIDTH, OLD_HEIGHT, ISFULLSCREENMODE=1.
# restore: put those five keys back to the saved values and drop the backups. Any other
#          option changed in-game during the stream is kept. The game is launched as a Sunshine
#          "detached" command, so it may still be running at undo time, and RO rewrites
#          OptionInfo.lua when it exits: if the client is running, restore is deferred to ONE
#          detached background waiter (pid file in $RO_BACKUP_DIR) that polls until the game exits
#          (gives up after RO_WAIT_MAX seconds, leaving the backup and recording an error).
# Only the value of existing `OptionInfoList["KEY"] = <number>` lines is touched, in a single
# sed pass written to a temp file next to the target and moved over it (atomic); every other
# byte (CRLF, comments, other options) is preserved. Always exits 0 so a missing client folder
# never aborts the stream; real restore failures go to $RO_BACKUP_DIR/LAST_ERRORS.
# Env: RO_OPTIONINFO (file path), STATE_DIR (volatile: stream size),
#      RO_BACKUP_DIR (persistent; default ${XDG_STATE_HOME:-~/.local/state}/ragnarok-stream),
#      PGREP (default pgrep), RO_PROC_PATTERN (default Ragexe), RO_POLL (default 2 s),
#      RO_WAIT_MAX (default 21600 s = 6 h).
set -euo pipefail
TMP=""
trap 'if [ -n "$TMP" ]; then rm -f "$TMP"; fi; exit 0' EXIT

SELF=$(readlink -f "${BASH_SOURCE[0]}")
here=$(dirname "$SELF")
# shellcheck source=lib.sh disable=SC1091
. "$here/lib.sh"

RO_OPTIONINFO=${RO_OPTIONINFO:-$HOME/Desktop/RO/savedata/OptionInfo.lua}
RO_OPTIONINFO=$(readlink -f "$RO_OPTIONINFO" 2>/dev/null || echo "$RO_OPTIONINFO")
KEYS=(WIDTH HEIGHT OLD_WIDTH OLD_HEIGHT ISFULLSCREENMODE)
SAVED=$RO_BACKUP_DIR/optioninfo.saved
ORIG=$RO_BACKUP_DIR/optioninfo.orig.lua
WAITER_PID=$RO_BACKUP_DIR/waiter.pid
PGREP=${PGREP:-pgrep}
RO_PROC_PATTERN=${RO_PROC_PATTERN:-Ragexe}
RO_POLL=${RO_POLL:-2}
RO_WAIT_MAX=${RO_WAIT_MAX:-21600}

# _get KEY: current numeric value in the file (empty if the line is absent).
_get() {
    sed -nE "s/^[[:space:]]*OptionInfoList\[\"$1\"\][[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" "$RO_OPTIONINFO" | head -n1
}

# _apply KEY=VALUE...: rewrite only the digits of those keys' lines, all in one sed pass, via a
# hidden temp file in the SAME directory (same filesystem, so mv is atomic); mode is kept.
_apply() {
    local kv
    local -a args=()
    for kv in "$@"; do
        args+=(-e "s/^([[:space:]]*OptionInfoList\\[\"${kv%%=*}\"\\][[:space:]]*=[[:space:]]*)[0-9]+/\\1${kv#*=}/")
    done
    # explicit && chain: callers use this inside `if`, where errexit is off
    TMP=$(mktemp "$(dirname "$RO_OPTIONINFO")/.OptionInfo.lua.XXXXXX") || return 1
    sed -E "${args[@]}" "$RO_OPTIONINFO" >"$TMP" &&
        chmod --reference="$RO_OPTIONINFO" "$TMP" &&
        mv -f "$TMP" "$RO_OPTIONINFO" || return 1
    TMP=""
}

game_running() { "$PGREP" -f "$RO_PROC_PATTERN" >/dev/null 2>&1; }

do_set() {
    local size=$STATE_DIR/stream-size w h k v
    if [ ! -r "$RO_OPTIONINFO" ] || [ ! -w "$RO_OPTIONINFO" ]; then
        log "warning: $RO_OPTIONINFO not readable/writable; leaving the game resolution alone"
        return 0
    fi
    if ! read -r w h <"$size" 2>/dev/null || ! _is_num "${w:-}" || ! _is_num "${h:-}"; then
        log "warning: no stream size in $size; leaving the game resolution alone"
        return 0
    fi
    mkdir -p "$RO_BACKUP_DIR"
    if [ -e "$SAVED" ]; then
        log "original options already saved; keeping them"
    else
        cp -p "$RO_OPTIONINFO" "$ORIG"
        : >"$SAVED.tmp"
        for k in "${KEYS[@]}"; do
            v=$(_get "$k")
            if [ -n "$v" ]; then echo "$k=$v" >>"$SAVED.tmp"; fi
        done
        mv "$SAVED.tmp" "$SAVED"
    fi
    _apply "WIDTH=$w" "OLD_WIDTH=$w" "HEIGHT=$h" "OLD_HEIGHT=$h" "ISFULLSCREENMODE=1"
    log "game resolution set to ${w}x${h} fullscreen"
}

restore_now() {
    local k v
    local -a pairs=()
    [ -e "$SAVED" ] || return 0
    if [ ! -w "$RO_OPTIONINFO" ]; then
        record_error ro-resolution.sh "cannot restore: $RO_OPTIONINFO is not writable (backup kept in $RO_BACKUP_DIR)"
        return 1
    fi
    while IFS='=' read -r k v; do
        if _is_num "$v"; then pairs+=("$k=$v"); fi
    done <"$SAVED"
    if [ "${#pairs[@]}" -gt 0 ] && ! _apply "${pairs[@]}"; then
        record_error ro-resolution.sh "restore failed writing $RO_OPTIONINFO (backup kept in $RO_BACKUP_DIR)"
        return 1
    fi
    rm -f "$SAVED" "$ORIG"
    log "game resolution restored"
}

waiter_alive() {
    local pid
    pid=$(cat "$WAITER_PID" 2>/dev/null || true)
    _is_num "$pid" && grep -q 'ro-resolution' "/proc/$pid/cmdline" 2>/dev/null
}

do_restore() {
    [ -e "$SAVED" ] || return 0
    if ! game_running; then
        restore_now
        return 0
    fi
    if waiter_alive; then
        log "game still running; a restore waiter is already pending"
        return 0
    fi
    log "game still running; restoring its resolution after it exits"
    setsid "$SELF" __wait </dev/null >/dev/null 2>&1 &
    echo "$!" >"$WAITER_PID"
    disown || true
}

do_wait() {
    echo "$$" >"$WAITER_PID"
    while game_running; do
        if [ "$SECONDS" -ge "$RO_WAIT_MAX" ]; then
            record_error ro-resolution.sh "game still running after ${RO_WAIT_MAX}s; backup kept in $RO_BACKUP_DIR (run ro-resolution.sh restore once it exits)"
            break
        fi
        sleep "$RO_POLL"
    done
    if ! game_running; then restore_now || true; fi
    if [ "$(cat "$WAITER_PID" 2>/dev/null || true)" = "$$" ]; then rm -f "$WAITER_PID"; fi
}

case "${1:-}" in
set) do_set || log "warning: set failed" ;;
restore) do_restore || log "warning: restore failed" ;;
__wait) do_wait ;;
*) log "usage: ro-resolution.sh set|restore" ;;
esac
exit 0
