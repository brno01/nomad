#!/usr/bin/env bash
# Auto-login by TYPING the password into the client's normal login form with ydotool (the SSO argv forms do not
# work on this server). Started detached by launch.sh right before it execs the game; runs once and exits.
#
# Requirements: "Memorizar" checked (the form opens with the user ID filled in and the focus in the password
# field), ydotoold running in the user session (socket $XDG_RUNTIME_DIR/.ydotool_socket), xdotool.
# Steps:
#   1. wait up to RO_TYPE_TIMEOUT (120 s), polling every RO_TYPE_POLL (1 s), until the ACTIVE X window name
#      contains "Ragnarok" AND a Ragexe_cerberus process exists;
#   2. sleep RO_LOGIN_DELAY (5 s) so the login dialog is drawn, then re-check the active window;
#   3. only if it is still Ragnarok: `printf %s "$pass" | ydotool type -d 40 -H 20 -f -` (the password goes via
#      STDIN only, never argv or env) and then `ydotool key 28:1 28:0` (Enter);
#   otherwise type NOTHING and record "auto-login skipped: Ragnarok window not active".
# The login file is re-read and validated here (login.sh); the password is never echoed or logged.
# ydotool types US-layout keycodes: alphanumeric passwords are safe, symbols may differ on ABNT2.
# Env: RO_LOGIN_FILE, YDOTOOL (default ydotool), YDOTOOL_SOCKET, XDOTOOL (default xdotool), PGREP (default pgrep),
# RO_TYPE_TIMEOUT, RO_TYPE_POLL, RO_LOGIN_DELAY, STATE_DIR, RO_BACKUP_DIR.
set -euo pipefail
trap 'exit 0' EXIT

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=../sunshine/lib.sh disable=SC1091
. "$here/../sunshine/lib.sh"
# shellcheck source=login.sh disable=SC1091
. "$here/login.sh"

YDOTOOL=${YDOTOOL:-ydotool}
XDOTOOL=${XDOTOOL:-xdotool}
PGREP=${PGREP:-pgrep}
YDOTOOL_SOCKET=${YDOTOOL_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket}
RO_TYPE_TIMEOUT=${RO_TYPE_TIMEOUT:-120}
RO_TYPE_POLL=${RO_TYPE_POLL:-1}
RO_LOGIN_DELAY=${RO_LOGIN_DELAY:-5}
export YDOTOOL_SOCKET

active_is_ragnarok() {
    local name
    name=$("$XDOTOOL" getactivewindow getwindowname 2>/dev/null) || return 1
    [[ $name == *Ragnarok* ]]
}
game_running() { "$PGREP" -f Ragexe_cerberus >/dev/null 2>&1; }
skip() { record_error autotype-login.sh "auto-login skipped: Ragnarok window not active${1:+ ($1)}"; }

main() {
    local rc=0 pass
    login_validate "$RO_LOGIN_FILE" || rc=$?
    if [ "$rc" != 0 ]; then
        [ "$rc" = 2 ] && log "$LOGIN_ERR"
        return 0
    fi
    pass=$LOGIN_PASS
    LOGIN_PASS=""
    if [ ! -e "$YDOTOOL_SOCKET" ]; then
        record_error autotype-login.sh "auto-login skipped: ydotool socket not found ($YDOTOOL_SOCKET)"
        return 0
    fi

    # EPOCHREALTIME (not SECONDS: that one counts wall-clock second boundaries, so a 1 s timeout can fire early)
    local deadline=$(( ${EPOCHREALTIME/[.,]/} + RO_TYPE_TIMEOUT * 1000000 ))
    until active_is_ragnarok && game_running; do
        if [ "${EPOCHREALTIME/[.,]/}" -ge "$deadline" ]; then
            skip "timeout after ${RO_TYPE_TIMEOUT}s"
            return 0
        fi
        sleep "$RO_TYPE_POLL"
    done
    sleep "$RO_LOGIN_DELAY"
    if ! active_is_ragnarok || ! game_running; then
        skip "changed during the login delay"
        return 0
    fi
    printf '%s' "$pass" | "$YDOTOOL" type -d 40 -H 20 -f -
    "$YDOTOOL" key 28:1 28:0
    log "auto-login: typed ${#pass} chars and Enter"
}

main || record_error autotype-login.sh "auto-login failed"
exit 0
