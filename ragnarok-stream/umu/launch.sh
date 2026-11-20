#!/usr/bin/env bash
# Launch the Ragnarok client with umu-run (umu-launcher: Proton outside Steam). It is the Sunshine app's blocking
# cmd and stays in the foreground (exec) until the game exits. No Steam account needed.
#
# Usage: launch.sh [--dry-run]     (--dry-run prints the env, cwd and command instead of running)
#
# Ported from the end of iniciar-cerberus.sh: `cd "$RO" && exec taskset -c "$PCORES" <wine> "$RO/Ragexe_cerberus.exe"`
# (no arguments), with the env it builds:
#   WINEDLLOVERRIDES=ddraw=n,b   D7VK ddraw.dll sitting next to the exe (D3D7 -> Vulkan)
#   WINE_CPU_TOPOLOGY=4:0,1,2,3  Wine only sees the P-cores (count:list); taskset pins the process to them
#   LANG/LC_ALL=pt_BR.UTF-8      locale (button labels of Windows dialogs)
#   PULSE_LATENCY_MSEC=60        DirectSound needs it with PipeWire (PULSE_SINK is not ported: it was a
#                                workaround for the standalone Wine build and a fixed sink name would break)
#   WINEDEBUG=-all, DXVK_LOG_LEVEL=warn
#   DXVK_CONFIG_FILE             only if dxvk.conf exists in the game dir (DXVK also reads it from the cwd)
# Optional auto-login: see login.sh and autotype-login.sh. Env: see common.sh, RO_LOGIN_FILE, YDOTOOL_SOCKET, AUTOTYPE.
set -euo pipefail

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=common.sh disable=SC1091
. "$here/common.sh"
# shellcheck source=login.sh disable=SC1091
. "$here/login.sh"
AUTOTYPE=${AUTOTYPE:-$here/autotype-login.sh}
YDOTOOL_SOCKET=${YDOTOOL_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket}
STATE_DIR=${STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/ragnarok-stream}

DRY=0
case "${1:-}" in
"") ;;
--dry-run) DRY=1 ;;
*)
    printf 'usage: %s [--dry-run]\n' "$0" >&2
    exit 2
    ;;
esac

pcores=$(detect_pcores)
env_lines=()
mapfile -t env_lines < <(umu_env)
env_lines+=("WINEDLLOVERRIDES=ddraw=n,b")
if [ -n "$pcores" ]; then
    env_lines+=("WINE_CPU_TOPOLOGY=$(tr ',' '\n' <<<"$pcores" | wc -l):$pcores")
else
    echo "warning: could not detect P-cores; no pinning/topology" >&2
fi
env_lines+=("LANG=$RO_LOCALE" "LC_ALL=$RO_LOCALE" "PULSE_LATENCY_MSEC=60" "WINEDEBUG=-all" "DXVK_LOG_LEVEL=warn")
if [ -f "$RO_DIR/dxvk.conf" ]; then env_lines+=("DXVK_CONFIG_FILE=$RO_DIR/dxvk.conf"); fi

# Optional auto-login (see login.sh, autotype-login.sh): the helper TYPES the password into the normal login form
# with ydotool. SSO via argv (-t:/1rag1 forms) did not work on this server. The password never goes through argv
# or env: the helper re-reads the validated file itself.
autotype=0
rc=0
login_validate "$RO_LOGIN_FILE" || rc=$?
if [ "$rc" = 2 ]; then
    echo "warning: $LOGIN_ERR" >&2
elif [ "$rc" = 0 ]; then
    if [ -e "$YDOTOOL_SOCKET" ]; then
        autotype=1
    else
        echo "warning: login file found but the ydotool socket is missing ($YDOTOOL_SOCKET); not auto-typing the password" >&2
    fi
fi
unset LOGIN_PASS LOGIN_USER

cmd=("$UMU_RUN" "$RO_DIR/$RO_EXE")
if [ -n "$pcores" ]; then cmd=(taskset -c "$pcores" "${cmd[@]}"); fi

if [ "$DRY" = 1 ]; then
    printf 'env:\n'
    printf '  %s\n' "${env_lines[@]}"
    printf 'cwd: %s\n' "$RO_DIR"
    printf 'command: %s\n' "${cmd[*]}"
    if [ "$autotype" = 1 ]; then printf 'auto-login: would start %s (types the saved password with ydotool)\n' "$AUTOTYPE"; fi
    exit 0
fi

[ -f "$RO_DIR/$RO_EXE" ] || die "$RO_DIR/$RO_EXE not found (set RO_DIR / RO_EXE)"
if ! command -v "$UMU_RUN" >/dev/null 2>&1 && [ ! -x "$UMU_RUN" ]; then die "umu-run not found ($UMU_RUN)"; fi
cd "$RO_DIR"
if [ "$autotype" = 1 ]; then
    mkdir -p "$STATE_DIR"
    setsid "$AUTOTYPE" </dev/null >>"$STATE_DIR/autotype.log" 2>&1 &
    disown || true
fi
exec env "${env_lines[@]}" "${cmd[@]}"
