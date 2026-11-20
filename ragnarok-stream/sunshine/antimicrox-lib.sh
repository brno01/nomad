# shellcheck shell=bash
# Helpers shared by antimicrox-start.sh / antimicrox-stop.sh (sourced; lib.sh must be sourced first).
#
# Why a watcher: Sunshine runs the prep-cmds when the client connects, but its virtual X360 pad is only
# created when Moonlight sends controller input (seconds later). AntiMicroX applies --profile only to pads
# that exist when it starts, so a hot-plugged pad gets no profile. The watcher therefore (re)starts AntiMicroX
# whenever the Sunshine pad appears (or is re-created).

AMX_PID=$STATE_DIR/antimicrox.pid
WATCH_PID=$STATE_DIR/antimicrox-watch.pid

# _cmd_has <pid> <word>...: pid is alive and its cmdline contains all the words (guards against pid reuse).
_cmd_has() {
    local pid=${1:-} cmd w
    shift
    _is_num "$pid" || return 1
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
    for w in "$@"; do [[ $cmd == *"$w"* ]] || return 1; done
}

amx_alive() { _cmd_has "${1:-}" antimicrox .amgp; }
watcher_alive() { _cmd_has "${1:-}" antimicrox-start.sh __watch; }

# _kill_ours <pidfile> <alive-function>: kill the process (and its group, we used setsid) if it is ours.
_kill_ours() {
    local pid
    [ -e "$1" ] || return 0
    pid=$(cat "$1" 2>/dev/null || true)
    if "$2" "$pid"; then
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
    rm -f "$1"
}
stop_amx() { _kill_ours "$AMX_PID" amx_alive; }
stop_watcher() { _kill_ours "$WATCH_PID" watcher_alive; }

# pad_handlers: print the sorted, space-separated event handlers (eventN) of the devices in
# $INPUT_DEVICES (default /proc/bus/input/devices) whose name matches $SUNSHINE_PAD_PATTERN
# (default: X-Box 360 / Xbox 360). Empty when there is no such device.
pad_handlers() {
    local file=${INPUT_DEVICES:-/proc/bus/input/devices} pattern=${SUNSHINE_PAD_PATTERN:-X-?Box 360}
    local line match=0 found=()
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ -z $line ]]; then
            match=0
        elif [[ $line == N:\ Name=* ]]; then
            if [[ $line =~ $pattern ]]; then match=1; else match=0; fi
        elif [[ $match == 1 && $line == H:\ Handlers=* ]]; then
            local tok
            for tok in ${line#H: Handlers=}; do
                if [[ $tok =~ ^event[0-9]+$ ]]; then found+=("$tok"); fi
            done
        fi
    done <"$file"
    if [ "${#found[@]}" -gt 0 ]; then printf '%s\n' "${found[@]}" | sort -u | paste -sd' ' -; fi
}
