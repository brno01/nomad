#!/usr/bin/env bash
# Local DNS failover for the nomad (installed as /usr/local/bin/nomad-dns-failover and run
# by nomad-dns-failover.timer every 30 s).
#
# The tailnet's only nameserver is the Pi-hole. If it stops answering, this turns
# Tailscale DNS off on the nomad (tailscale set --accept-dns=false) so the nomad falls back
# to the DNS of the network it is on; once the Pi-hole answers again it turns Tailscale DNS
# back on. It only re-enables what it disabled itself: a manual --accept-dns=false is kept.
# The tailnet-wide failover (GitHub Actions, repo tailnet-dns-failover) takes 5-15 min;
# this covers the nomad in about a minute.
#
# Env: PIHOLE_IP (required), PROBE_NAME (default example.com), FAILS_BEFORE_SWITCH (default 2),
#      STATE_DIR (default /var/lib/nomad-dns-failover), TAILSCALE, DIG (for tests)
set -euo pipefail

: "${PIHOLE_IP:?set PIHOLE_IP}"
PROBE_NAME=${PROBE_NAME:-example.com}
FAILS_BEFORE_SWITCH=${FAILS_BEFORE_SWITCH:-2}
STATE_DIR=${STATE_DIR:-/var/lib/nomad-dns-failover}
TAILSCALE=${TAILSCALE:-tailscale}
DIG=${DIG:-dig}

FAILS_FILE="$STATE_DIR/fails"
MARKER="$STATE_DIR/disabled-by-failover"

log() { printf '%s\n' "$*"; }

mkdir -p "$STATE_DIR"

state=$("$TAILSCALE" status --json 2>/dev/null | jq -r '.BackendState // empty') || state=""
if [ "$state" != Running ]; then
    log "tailscale is not running ($state); nothing to do"
    exit 0
fi

accept_dns=$("$TAILSCALE" debug prefs | jq -r '.CorpDNS')

pihole_up() {
    "$DIG" +tries=1 +time=2 "@$PIHOLE_IP" "$PROBE_NAME" A 2>/dev/null | grep -q 'status: NOERROR'
}

if pihole_up; then
    rm -f "$FAILS_FILE"
    if [ -e "$MARKER" ]; then
        if [ "$accept_dns" = false ]; then
            "$TAILSCALE" set --accept-dns=true
            log "pihole answers again: tailscale DNS back on"
        fi
        rm -f "$MARKER"
    fi
    exit 0
fi

fails=$(( $(cat "$FAILS_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$FAILS_FILE"
log "pihole did not answer ($fails/$FAILS_BEFORE_SWITCH)"

if [ "$fails" -ge "$FAILS_BEFORE_SWITCH" ] && [ "$accept_dns" = true ]; then
    "$TAILSCALE" set --accept-dns=false
    touch "$MARKER"
    log "tailscale DNS off: using the local network's DNS until the pihole is back"
fi
