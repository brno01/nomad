#!/usr/bin/env bash
# Turns Wi-Fi power save off for good on the nomad.
#
# With power save on, the access point buffers frames for the sleeping radio until the
# next beacon, so traffic *arriving* at the nomad waits 30-100 ms. That hit every
# tailnet packet (Tailscale replies, Pi-hole DNS answers). Measured on 2026-11-11:
# tailnet RTT to atheron 30-80 ms with power save on, ~2.5 ms with it off.
#
# Installs a NetworkManager drop-in (wifi.powersave = 2, i.e. disabled) that applies to
# every Wi-Fi connection whose own setting is "default", then turns power save off on
# the Wi-Fi interfaces that are up right now, so no reconnect is needed.
#
# Usage: scripts/wifi-powersave.sh [--dry-run | --undo]
# Env (for tests): NM_CONF_DIR, SKIP_APPLY=1
set -euo pipefail

NM_CONF_DIR=${NM_CONF_DIR:-/etc/NetworkManager/conf.d}
SKIP_APPLY=${SKIP_APPLY:-0}
CONF="$NM_CONF_DIR/90-nomad-wifi-powersave-off.conf"
MODE=apply

case "${1:-}" in
    --dry-run) MODE=dry-run ;;
    --undo) MODE=undo ;;
    "") ;;
    *) printf 'usage: %s [--dry-run | --undo]\n' "$0" >&2; exit 2 ;;
esac

SUDO=""
if [ "$(id -u)" -ne 0 ] && [ ! -w "$NM_CONF_DIR" ]; then
    SUDO=sudo
fi

log() { printf '%s\n' "$*"; }

wifi_ifaces() {
    local dev
    for dev in /sys/class/net/*; do
        [ -d "$dev/wireless" ] && basename "$dev"
    done
    return 0
}

# set_live <on|off>: change power save on the interfaces that are up now
set_live() {
    local state=$1 iface
    [ "$SKIP_APPLY" = 1 ] && return 0
    while read -r iface; do
        [ -n "$iface" ] || continue
        if $SUDO iw dev "$iface" set power_save "$state" 2>/dev/null; then
            log "live    $iface power_save $state"
        else
            log "warn    could not set power_save $state on $iface" >&2
        fi
    done < <(wifi_ifaces)
}

reload_nm() {
    [ "$SKIP_APPLY" = 1 ] && return 0
    $SUDO nmcli general reload conf
}

if [ "$MODE" = undo ]; then
    if [ -f "$CONF" ]; then
        $SUDO rm -f "$CONF"
        log "removed $CONF"
        reload_nm
    else
        log "ok      $CONF already absent"
    fi
    set_live on
    exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'EOF'
# nomad-enhancement: Wi-Fi power save off (scripts/wifi-powersave.sh)
# 2 = disable. Applies to Wi-Fi connections whose 802-11-wireless.powersave is "default".
[connection]
wifi.powersave = 2
EOF

if [ -f "$CONF" ] && cmp -s "$tmp" "$CONF"; then
    log "ok      $CONF"
elif [ "$MODE" = dry-run ]; then
    log "would write $CONF"
    exit 0
else
    $SUDO install -D -m 0644 "$tmp" "$CONF"
    log "wrote   $CONF"
    reload_nm
fi

[ "$MODE" = dry-run ] && exit 0
set_live off
