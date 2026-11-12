#!/usr/bin/env bash
# Installs the Obsidian export of the nomad docs: nomad-obsidian.{service,timer}
# (systemd --user, every 10 min) running obsidian/export_nomad.py, and merges the
# nomad colors/search into the vault's graph.json (export_nomad.py --graph).
#
# Usage: scripts/obsidian-install.sh [--dry-run | --undo]
# Env: For tests: UNIT_DIR, UV, SKIP_SYSTEMCTL=1, SKIP_EXPORT=1
set -euo pipefail

UNIT_DIR=${UNIT_DIR:-$HOME/.config/systemd/user}
SKIP_SYSTEMCTL=${SKIP_SYSTEMCTL:-0}
SKIP_EXPORT=${SKIP_EXPORT:-0}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODE=apply

case "${1:-}" in
    --dry-run) MODE=dry-run ;;
    --undo) MODE=undo ;;
    "") ;;
    *) printf 'usage: %s [--dry-run | --undo]\n' "$0" >&2; exit 2 ;;
esac

log() { printf '%s\n' "$*"; }
sctl() { [ "$SKIP_SYSTEMCTL" = 1 ] || systemctl --user "$@"; }

SERVICE="$UNIT_DIR/nomad-obsidian.service"
TIMER="$UNIT_DIR/nomad-obsidian.timer"

if [ "$MODE" = undo ]; then
    sctl disable --now nomad-obsidian.timer 2>/dev/null || true
    for f in "$TIMER" "$SERVICE"; do
        if [ -e "$f" ]; then rm -f "$f"; log "removed $f"; else log "ok      $f already absent"; fi
    done
    sctl daemon-reload
    log "note: the generated notes stay in the vault (projects/nomad, files marked 'gerado por')."
    exit 0
fi

UV=${UV:-$(command -v uv || true)}
if [ -z "$UV" ]; then
    log "uv not found (install it with: brew install uv)" >&2
    exit 1
fi

changed=0
# install_file <dest> < content   (only touches dest when the content changed)
install_file() {
    local dest=$1 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        log "ok      $dest"
    elif [ "$MODE" = dry-run ]; then
        log "would write $dest"
    else
        install -D -m 0644 "$tmp" "$dest"
        log "wrote   $dest"
        changed=1
    fi
    rm -f "$tmp"
}

install_file "$SERVICE" <<EOF
# nomad-enhancement: scripts/obsidian-install.sh
[Unit]
Description=Export the nomad docs to the Obsidian vault
After=network-online.target

[Service]
Type=oneshot
ExecStart=$UV run --no-project python -I $REPO/obsidian/export_nomad.py
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=15min
EOF

install_file "$TIMER" <<'EOF'
# nomad-enhancement: scripts/obsidian-install.sh
[Unit]
Description=Export the nomad docs to Obsidian every 10 min (only writes when something changed)

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF

if [ "$SKIP_EXPORT" != 1 ]; then
    if [ "$MODE" = dry-run ]; then
        "$UV" run --no-project python -I "$REPO/obsidian/export_nomad.py" --graph --dry-run
    else
        "$UV" run --no-project python -I "$REPO/obsidian/export_nomad.py" --graph
    fi
fi

[ "$MODE" = dry-run ] && exit 0
[ "$changed" = 1 ] && sctl daemon-reload
sctl enable --now nomad-obsidian.timer
