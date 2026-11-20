#!/usr/bin/env bash
# One-time bootstrap of the dedicated umu prefix: `umu-run wineboot -u` with our umu env.
# The FIRST umu-run downloads the Steam Linux Runtime and Proton (GE-Proton by default): several GB,
# minutes. Run it once, ideally in the background, and wait for it before setup-prefix.sh:
#     ragnarok-stream/umu/bootstrap.sh > /tmp/ragnarok-bootstrap.log 2>&1 &
# Usage: bootstrap.sh [--dry-run]. Idempotent: skips if the prefix already has a registry.
set -euo pipefail

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=common.sh disable=SC1091
. "$here/common.sh"

DRY=0
case "${1:-}" in
"") ;;
--dry-run) DRY=1 ;;
*)
    printf 'usage: %s [--dry-run]\n' "$0" >&2
    exit 2
    ;;
esac

if prefix_bootstrapped; then
    log "ok      prefix already bootstrapped: $RO_PREFIX"
    exit 0
fi
if [ "$DRY" = 1 ]; then
    log "would run: umu-run wineboot -u (WINEPREFIX=$RO_PREFIX PROTONPATH=$PROTONPATH GAMEID=$GAMEID STORE=$STORE)"
    exit 0
fi
if ! command -v "$UMU_RUN" >/dev/null 2>&1 && [ ! -x "$UMU_RUN" ]; then die "umu-run not found ($UMU_RUN)"; fi

mkdir -p "$RO_PREFIX"
log "bootstrapping $RO_PREFIX (first run downloads the runtime and Proton: GBs, minutes)..."
umu wineboot -u || die "wineboot -u failed"
prefix_bootstrapped || die "wineboot finished but $RO_PREFIX has no registry yet"
log "done    prefix ready: $RO_PREFIX"
