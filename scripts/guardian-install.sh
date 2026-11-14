#!/usr/bin/env bash
# Installs the Obsidian guardian: nomad-obsidian-guardian.service (systemd --user, always running,
# restarts on failure) running obsidian/guardian.py. It keeps the vault's graph colors, "Pai:" links,
# tags, duplicates and links right (see the docstring of guardian.py and obsidian/guardian.toml).
#
# Usage: scripts/guardian-install.sh [--dry-run | --undo]
# Env: For tests: UNIT_DIR, UV, SKIP_SYSTEMCTL=1
set -euo pipefail

UNIT_DIR=${UNIT_DIR:-$HOME/.config/systemd/user}
SKIP_SYSTEMCTL=${SKIP_SYSTEMCTL:-0}
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

SERVICE="$UNIT_DIR/nomad-obsidian-guardian.service"

if [ "$MODE" = undo ]; then
    sctl disable --now nomad-obsidian-guardian.service 2>/dev/null || true
    if [ -e "$SERVICE" ]; then rm -f "$SERVICE"; log "removed $SERVICE"; else log "ok      $SERVICE already absent"; fi
    sctl daemon-reload
    log "note: notes already fixed and anything moved to archive/guardiao/ stay in the vault."
    exit 0
fi

UV=${UV:-$(command -v uv || true)}
if [ -z "$UV" ]; then
    log "uv not found (install it with: brew install uv)" >&2
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<UNIT
# nomad-enhancement: scripts/guardian-install.sh
[Unit]
Description=Keep the Obsidian vault graph (colors, parents, tags, links) correct, always running

[Service]
Type=simple
ExecStart=$UV run --no-project python -I $REPO/obsidian/guardian.py
Restart=always
RestartSec=30
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=default.target
UNIT

changed=0
if [ -f "$SERVICE" ] && cmp -s "$tmp" "$SERVICE"; then
    log "ok      $SERVICE"
elif [ "$MODE" = dry-run ]; then
    log "would write $SERVICE"
else
    install -D -m 0644 "$tmp" "$SERVICE"
    log "wrote   $SERVICE"
    changed=1
fi

[ "$MODE" = dry-run ] && exit 0
[ "$changed" = 1 ] && sctl daemon-reload
sctl enable --now nomad-obsidian-guardian.service
[ "$changed" = 1 ] && sctl restart nomad-obsidian-guardian.service
exit 0
