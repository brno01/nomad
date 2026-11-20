#!/usr/bin/env bash
# Installs the nomad's local DNS failover: /usr/local/bin/nomad-dns-failover plus
# nomad-dns-failover.{service,timer} (every 30 s). See scripts/dns-failover.sh.
#
# Usage: scripts/dns-failover-install.sh [--dry-run | --undo]
# Env: PIHOLE_IP (the Pi-hole address; required to install). When it is not set, the
#      installer reads it from config.local.env at the repository root (not versioned;
#      copy config.example.env).
#      For tests: ETC_DIR, BIN_DIR, SKIP_SYSTEMCTL=1
set -euo pipefail

ETC_DIR=${ETC_DIR:-/etc/systemd/system}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
SKIP_SYSTEMCTL=${SKIP_SYSTEMCTL:-0}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCAL_ENV=${LOCAL_ENV:-$SCRIPT_DIR/../config.local.env}
if [ -z "${PIHOLE_IP:-}" ] && [ -f "$LOCAL_ENV" ]; then
    PIHOLE_IP=$(sed -n 's/^PIHOLE_IP=//p' "$LOCAL_ENV" | tail -n 1)
fi
MODE=apply

case "${1:-}" in
    --dry-run) MODE=dry-run ;;
    --undo) MODE=undo ;;
    "") ;;
    *) printf 'usage: %s [--dry-run | --undo]\n' "$0" >&2; exit 2 ;;
esac

SUDO=""
if [ "$(id -u)" -ne 0 ] && { [ ! -w "$ETC_DIR" ] || [ ! -w "$BIN_DIR" ]; }; then
    SUDO=sudo
fi

log() { printf '%s\n' "$*"; }
sctl() { [ "$SKIP_SYSTEMCTL" = 1 ] || $SUDO systemctl "$@"; }

BIN="$BIN_DIR/nomad-dns-failover"
SERVICE="$ETC_DIR/nomad-dns-failover.service"
TIMER="$ETC_DIR/nomad-dns-failover.timer"

if [ "$MODE" = undo ]; then
    sctl disable --now nomad-dns-failover.timer 2>/dev/null || true
    for f in "$TIMER" "$SERVICE" "$BIN"; do
        if [ -e "$f" ]; then $SUDO rm -f "$f"; log "removed $f"; else log "ok      $f already absent"; fi
    done
    sctl daemon-reload
    log "note: if the failover had turned tailscale DNS off, turn it back on with: tailscale set --accept-dns=true"
    exit 0
fi

if [ -z "${PIHOLE_IP:-}" ]; then
    printf 'error: set PIHOLE_IP or create %s from config.example.env\n' "$LOCAL_ENV" >&2
    exit 2
fi

changed=0
# install_file <mode> <dest> < content   (only touches dest when the content changed)
install_file() {
    local mode=$1 dest=$2 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        log "ok      $dest"
    elif [ "$MODE" = dry-run ]; then
        log "would write $dest"
    else
        $SUDO install -D -m "$mode" "$tmp" "$dest"
        log "wrote   $dest"
        changed=1
    fi
    rm -f "$tmp"
}

install_file 0755 "$BIN" < "$SCRIPT_DIR/dns-failover.sh"

install_file 0644 "$SERVICE" <<EOF
# nomad-enhancement: scripts/dns-failover-install.sh
[Unit]
Description=Turn Tailscale DNS off while the Pi-hole does not answer
After=tailscaled.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PIHOLE_IP=$PIHOLE_IP
ExecStart=$BIN
EOF

install_file 0644 "$TIMER" <<'EOF'
# nomad-enhancement: scripts/dns-failover-install.sh
[Unit]
Description=Check the Pi-hole every 30 s (nomad DNS failover)

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

[ "$MODE" = dry-run ] && exit 0
[ "$changed" = 1 ] && sctl daemon-reload
sctl enable --now nomad-dns-failover.timer
