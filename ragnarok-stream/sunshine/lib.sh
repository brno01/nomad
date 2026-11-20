# shellcheck shell=bash
# Shared helpers for prep.sh / undo.sh (sourced, not executed).
#
# Brightness backends, tried in order:
#   plasma6   org.kde.ScreenBrightness (Plasma 6.2+), via busctl --user
#             /org/kde/ScreenBrightness            property DisplaysDBusNames (as)
#             /org/kde/ScreenBrightness/<name>     iface org.kde.ScreenBrightness.Display
#               props IsInternal (b), Brightness (i), MaxBrightness (i)
#               method SetBrightness(i brightness, u flags)  flags 0x1 = SuppressIndicator
#             Source: plasma/powerdevil daemon/dbus/org.kde.ScreenBrightness{,.Display}.xml
#   legacy    org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/BrightnessControl
#             methods brightness, setBrightness(i), brightnessMax
#   bctl      brightnessctl -c backlight
# State line format: "<backend> <display> <value>" (display is "-" when n/a).

BUSCTL=${BUSCTL:-busctl}
BRIGHTNESSCTL=${BRIGHTNESSCTL:-brightnessctl}
SYSTEMD_INHIBIT=${SYSTEMD_INHIBIT:-systemd-inhibit}
STATE_DIR=${STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/ragnarok-stream}
INHIBIT_WHO=ragnarok-stream
# shellcheck disable=SC2034 # used by prep.sh
MIN_BRIGHTNESS=1 # minimum NON-zero: some panels turn the backlight off at 0

# Persistent dir (survives reboots) for the OptionInfo.lua backup and the LAST_ERRORS trace.
RO_BACKUP_DIR=${RO_BACKUP_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ragnarok-stream}

log() { printf 'ragnarok-stream: %s\n' "$*" >&2; }

# record_error <component> <message>: log it AND leave a visible trace that
# `ragnarok-stream-install.sh --check` reports. Never fails.
record_error() {
    log "error: $2"
    { mkdir -p "$RO_BACKUP_DIR" && printf '%s %s: %s\n' "$(date -Is)" "$1" "$2" >>"$RO_BACKUP_DIR/LAST_ERRORS"; } 2>/dev/null || true
}

# Wrapper so a hung bus never blocks Sunshine.
_bus() { timeout 5 "$BUSCTL" --user "$@" 2>/dev/null; }

# Last whitespace-separated field of "i 1234" / "b true".
_val() { awk 'NF { print $NF; exit }'; }

_is_num() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

P6_SVC=org.kde.ScreenBrightness
P6_ROOT=/org/kde/ScreenBrightness
P6_DISPLAY_IFACE=org.kde.ScreenBrightness.Display
LG_SVC=org.kde.Solid.PowerManagement
LG_PATH=/org/kde/Solid/PowerManagement/Actions/BrightnessControl
LG_IFACE=org.kde.Solid.PowerManagement.Actions.BrightnessControl

# Print the D-Bus name of the first internal display, if any.
_p6_internal_display() {
    local out name internal
    out=$(_bus get-property "$P6_SVC" "$P6_ROOT" "$P6_SVC" DisplaysDBusNames) || return 1
    while read -r name; do
        [ -n "$name" ] || continue
        internal=$(_bus get-property "$P6_SVC" "$P6_ROOT/$name" "$P6_DISPLAY_IFACE" IsInternal | _val) || continue
        if [ "$internal" = true ]; then
            printf '%s\n' "$name"
            return 0
        fi
    done < <(grep -o '"[^"]*"' <<<"$out" | tr -d '"')
    return 1
}

# brightness_get: print "<backend> <display> <value>" for the first working backend.
brightness_get() {
    local d v
    if d=$(_p6_internal_display) && [ -n "$d" ]; then
        v=$(_bus get-property "$P6_SVC" "$P6_ROOT/$d" "$P6_DISPLAY_IFACE" Brightness | _val) || v=""
        if _is_num "$v"; then
            echo "plasma6 $d $v"
            return 0
        fi
    fi
    v=$(_bus call "$LG_SVC" "$LG_PATH" "$LG_IFACE" brightness | _val) || v=""
    if _is_num "$v"; then
        echo "legacy - $v"
        return 0
    fi
    if command -v "$BRIGHTNESSCTL" >/dev/null 2>&1; then
        v=$("$BRIGHTNESSCTL" -c backlight g 2>/dev/null) || v=""
        if _is_num "$v"; then
            echo "bctl - $v"
            return 0
        fi
    fi
    return 1
}

# brightness_set <backend> <display> <value>
brightness_set() {
    case $1 in
    plasma6) _bus call "$P6_SVC" "$P6_ROOT/$2" "$P6_DISPLAY_IFACE" SetBrightness iu "$3" 1 >/dev/null ;;
    legacy) _bus call "$LG_SVC" "$LG_PATH" "$LG_IFACE" setBrightness i "$3" >/dev/null ;;
    bctl) "$BRIGHTNESSCTL" -c backlight set "$3" >/dev/null 2>&1 ;;
    *) return 1 ;;
    esac
}

# p6_resolve_display <saved name>: the saved D-Bus object may be gone (vmon-stop re-enables the panel and KDE
# can expose it under a new name, e.g. display0 -> display1). Print the saved name if it is still listed,
# else the current internal display; print nothing if neither exists.
p6_resolve_display() {
    local out
    out=$(_bus get-property "$P6_SVC" "$P6_ROOT" "$P6_SVC" DisplaysDBusNames) || out=""
    if [ -n "$out" ] && grep -q "\"$1\"" <<<"$out"; then
        printf '%s\n' "$1"
        return 0
    fi
    _p6_internal_display || true
}

# True if PID is alive and is our inhibitor (guards against PID reuse).
inhibitor_alive() {
    local pid=${1:-} cmd
    _is_num "$pid" || return 1
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ $cmd == *"--who=$INHIBIT_WHO"* ]]
}
