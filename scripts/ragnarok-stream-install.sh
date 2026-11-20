#!/usr/bin/env bash
# Installs the Ragnarok-over-Sunshine streaming setup ON nomad (by the user or over SSH). No sudo, no Steam.
# Paths derive from this script's location, so a deployed copy (e.g. ~/.local/share/ragnarok-stream with
# scripts/ and ragnarok-stream/) works as is.
#   1. systemd drop-in for the Sunshine unit (libva driver path, ExecStopPost)
#   2. AntiMicroX (Flatpak, user install; skipped when already installed for the user or system-wide)
#   3. AntiMicroX profile check (ragnarok-stream/antimicrox/*.amgp must match build_profile.py)
#   4. Sunshine app "Ragnarok" in apps.json + sunshine.conf keys
#   5. umu prefix: bootstrap check, then the font setup once it is bootstrapped
#
# Usage: scripts/ragnarok-stream-install.sh [--dry-run | --undo | --check]
#          [--skip-antimicrox] [--skip-sunshine] [--skip-prefix]
#   --undo       removes the app, the conf keys and the drop-in. It does NOT uninstall AntiMicroX
#                nor delete the prefix (it prints how to do both by hand).
#   --check      read-only report; non-zero if anything is missing/stale, if the brew Sunshine binary has file
#                capabilities (libva then ignores LIBVA_DRIVERS_PATH; fix: sudo setcap -r <binary>, never run
#                by this script), or if $RO_BACKUP_DIR/LAST_ERRORS exists.
# Env (also for tests): RO_DIR, RO_PREFIX, SUNSHINE_APPS, SUNSHINE_CONF, UNIT_DIR, SKIP_SYSTEMCTL=1, GETCAP,
# SUNSHINE_BIN, RO_BACKUP_DIR, RO_LOGIN_FILE, YDOTOOL, YDOTOOL_SOCKET, XDOTOOL, FLATPAK, ANTIMICROX_APP, PYTHON, RO_AMGP_DIR.
# --check also reports the optional auto-login file (umu/login.sh): absent = informational; present with
# bad permissions/content = failure; present and valid also needs the ydotool socket, ydotool and xdotool.
set -euo pipefail

REPO=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
RS=$REPO/ragnarok-stream
MODE=apply
SKIP_AMX=0 SKIP_SUNSHINE=0 SKIP_PREFIX=0
RO_DIR=${RO_DIR:-$HOME/Desktop/RO}
RO_PREFIX=${RO_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/ragnarok-stream/pfx}
UNIT_DIR=${UNIT_DIR:-$HOME/.config/systemd/user}
SKIP_SYSTEMCTL=${SKIP_SYSTEMCTL:-0}
GETCAP=${GETCAP:-getcap}
SUNSHINE_BIN=${SUNSHINE_BIN:-/home/linuxbrew/.linuxbrew/opt/sunshine/bin/sunshine}
RO_BACKUP_DIR=${RO_BACKUP_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ragnarok-stream}
FLATPAK=${FLATPAK:-flatpak}
ANTIMICROX_APP=${ANTIMICROX_APP:-io.github.antimicrox.antimicrox}
FLATHUB_URL=https://dl.flathub.org/repo/flathub.flatpakrepo
PYTHON=${PYTHON:-python3}
RO_AMGP_DIR=${RO_AMGP_DIR:-$RS/antimicrox}
DROPIN_DIR=$UNIT_DIR/app-dev.lizardbyte.app.Sunshine.service.d
DROPIN=$DROPIN_DIR/10-nomad-enhancement.conf
export SUNSHINE_APPS SUNSHINE_CONF RO_DIR RO_PREFIX RO_BACKUP_DIR

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}
log() { printf '%s\n' "$*"; }
sctl() { [ "$SKIP_SYSTEMCTL" = 1 ] || systemctl --user "$@"; }
have_flatpak() { command -v "$FLATPAK" >/dev/null 2>&1 || [ -x "$FLATPAK" ]; }
amx_installed() { have_flatpak && "$FLATPAK" info "$ANTIMICROX_APP" >/dev/null 2>&1; }
bootstrapped() { [ -s "$RO_PREFIX/system.reg" ] && [ -d "$RO_PREFIX/drive_c/windows" ]; }
profile_check() {
    "$PYTHON" -I "$RS/antimicrox/build_profile.py" --check --out "$RO_AMGP_DIR/ragnarok.amgp" 2>&1
}

while [ $# -gt 0 ]; do
    case $1 in
    --dry-run) MODE=dry-run; shift ;;
    --undo) MODE=undo; shift ;;
    --check) MODE=check; shift ;;
    --skip-antimicrox) SKIP_AMX=1; shift ;;
    --skip-sunshine) SKIP_SUNSHINE=1; shift ;;
    --skip-prefix) SKIP_PREFIX=1; shift ;;
    *) usage ;;
    esac
done
DRY=()
[ "$MODE" = dry-run ] && DRY=(--dry-run)

# ---- undo ---------------------------------------------------------------

if [ "$MODE" = undo ]; then
    if [ "$SKIP_SUNSHINE" = 0 ]; then
        "$RS/sunshine/install-app.sh" --undo
        if [ -e "$DROPIN" ]; then
            rm -f "$DROPIN"
            rmdir "$DROPIN_DIR" 2>/dev/null || true
            sctl daemon-reload
            log "removed $DROPIN (restart Sunshine to apply)"
        else
            log "ok      drop-in already absent"
        fi
    fi
    log "left in place on purpose; remove by hand if you want:"
    log "  AntiMicroX:  flatpak uninstall --user $ANTIMICROX_APP   (or without --user if it was installed system-wide)"
    log "  umu prefix:  rm -rf $RO_PREFIX"
    exit 0
fi

# ---- check --------------------------------------------------------------

if [ "$MODE" = check ]; then
    bad=0
    ok() { log "ok      $*"; }
    miss() { log "missing $*"; bad=1; }
    if [ "$SKIP_SUNSHINE" = 0 ]; then
        if cmp -s "$RS/sunshine/10-nomad-enhancement.conf" "$DROPIN"; then ok "Sunshine systemd drop-in"; else miss "Sunshine systemd drop-in $DROPIN"; fi
        apps=${SUNSHINE_APPS:-$HOME/.config/sunshine/apps.json}
        if [ -r "$apps" ] && jq -e '.apps[]? | select(.name=="Ragnarok")' "$apps" >/dev/null 2>&1; then ok "Sunshine app"; else miss "Sunshine app"; fi
        conf=${SUNSHINE_CONF:-$HOME/.config/sunshine/sunshine.conf}
        if grep -qx 'capture = kwin' "$conf" 2>/dev/null; then ok "sunshine.conf (capture = kwin)"; else miss "sunshine.conf keys"; fi
        bin=$(readlink -f "$SUNSHINE_BIN" 2>/dev/null || true)
        if [ -n "$bin" ] && [ -e "$bin" ]; then
            caps=$("$GETCAP" "$bin" 2>/dev/null || true)
            if [ -n "$caps" ]; then
                log "FAIL    file capabilities on the Sunshine binary: $caps"
                log "        libva ignores LIBVA_DRIVERS_PATH for such binaries (software x264 fallback); KWin capture does not need them."
                log "        fix (run it yourself): sudo setcap -r $bin"
                bad=1
            else
                ok "no file capabilities on $bin"
            fi
        else
            log "skip    capabilities check: Sunshine binary not found ($SUNSHINE_BIN)"
        fi
    fi
    if [ "$SKIP_AMX" = 0 ]; then
        if amx_installed; then ok "AntiMicroX installed"; else miss "AntiMicroX ($ANTIMICROX_APP)"; fi
        if out=$(profile_check); then ok "AntiMicroX profile up to date"; else log "FAIL    AntiMicroX profile stale: $out"; bad=1; fi
    fi
    if [ "$SKIP_PREFIX" = 0 ]; then
        if bootstrapped; then
            ok "umu prefix bootstrapped"
            if [ -e "$RO_PREFIX/.ragnarok-fonts-v1" ]; then ok "prefix fonts"; else miss "prefix fonts (re-run the installer)"; fi
        else
            miss "umu prefix not bootstrapped (run $RS/umu/bootstrap.sh, wait, then re-run the installer)"
        fi
    fi
    # shellcheck source=../ragnarok-stream/umu/login.sh disable=SC1091
    . "$RS/umu/login.sh"
    lrc=0
    login_validate "$RO_LOGIN_FILE" || lrc=$?
    case $lrc in
    0)
        ok "login file $RO_LOGIN_FILE valid (auto-login on)"
        # the password is typed with ydotool into the active X window: needs ydotoold's socket, ydotool, xdotool
        sock=${YDOTOOL_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket}
        if [ -e "$sock" ]; then ok "ydotool socket $sock"; else log "FAIL    ydotool socket missing ($sock): start ydotoold in your session"; bad=1; fi
        for t in "${YDOTOOL:-ydotool}" "${XDOTOOL:-xdotool}"; do
            if command -v "$t" >/dev/null 2>&1 || [ -x "$t" ]; then ok "$(basename "$t") available"; else log "FAIL    $(basename "$t") not found (needed by the login auto-type)"; bad=1; fi
        done
        ;;
    1) log "info    login file absent (auto-login off): $RO_LOGIN_FILE" ;;
    *)
        log "FAIL    $LOGIN_ERR"
        bad=1
        ;;
    esac
    errs=$RO_BACKUP_DIR/LAST_ERRORS
    if [ -s "$errs" ]; then
        log "FAIL    errors left by the stream scripts ($errs), last lines:"
        tail -n 5 "$errs" | sed 's/^/        /'
        log "        fix the cause (OptionInfo.lua backup: $RO_BACKUP_DIR), then clear with: rm $errs"
        bad=1
    else
        ok "no recorded stream-script errors"
    fi
    exit "$bad"
fi

# ---- apply / dry-run ------------------------------------------------------

[ -f "$RO_DIR/Ragexe_cerberus.exe" ] || log "warning: $RO_DIR/Ragexe_cerberus.exe not found (set RO_DIR)"
command -v umu-run >/dev/null 2>&1 || [ -n "${UMU_RUN:-}" ] || log "warning: umu-run not found in PATH"

# 1. systemd drop-in
if [ "$SKIP_SUNSHINE" = 0 ]; then
    if cmp -s "$RS/sunshine/10-nomad-enhancement.conf" "$DROPIN"; then
        log "ok      $DROPIN"
    elif [ "$MODE" = dry-run ]; then
        log "would write $DROPIN"
    else
        install -D -m 0644 "$RS/sunshine/10-nomad-enhancement.conf" "$DROPIN"
        sctl daemon-reload
        log "wrote   $DROPIN (restart Sunshine: systemctl --user restart app-dev.lizardbyte.app.Sunshine.service)"
    fi
fi

# 2. AntiMicroX (user Flatpak, no sudo)
if [ "$SKIP_AMX" = 0 ]; then
    if ! have_flatpak; then
        echo "error: flatpak not found ($FLATPAK); cannot install AntiMicroX (use --skip-antimicrox to skip)" >&2
        exit 1
    fi
    if amx_installed; then
        log "ok      AntiMicroX already installed"
    elif [ "$MODE" = dry-run ]; then
        log "would run: flatpak remote-add --user --if-not-exists flathub $FLATHUB_URL"
        log "would run: flatpak install --user -y --noninteractive flathub $ANTIMICROX_APP"
    else
        "$FLATPAK" remote-add --user --if-not-exists flathub "$FLATHUB_URL"
        "$FLATPAK" install --user -y --noninteractive flathub "$ANTIMICROX_APP"
        log "wrote   AntiMicroX installed ($ANTIMICROX_APP)"
    fi

    # 3. profile check
    if ! out=$(profile_check); then
        echo "error: the AntiMicroX profile is stale: $out" >&2
        exit 1
    fi
    log "ok      AntiMicroX profile up to date"
fi

# 4. Sunshine app + conf
if [ "$SKIP_SUNSHINE" = 0 ]; then
    "$RS/sunshine/install-app.sh" --app --set-conf --repo "$REPO" "${DRY[@]}"
fi

# 5. umu prefix: bootstrap check, then fonts
if [ "$SKIP_PREFIX" = 0 ]; then
    if bootstrapped; then
        "$RS/umu/setup-prefix.sh" "${DRY[@]}" || log "warning: font setup failed (see above); fix it and re-run this script"
    else
        log "prefix: not bootstrapped yet, fonts skipped. Run once and WAIT (the first run downloads GBs):"
        log "  $RS/umu/bootstrap.sh > /tmp/ragnarok-bootstrap.log 2>&1 &"
        log "then re-run this script for the fonts."
    fi
fi
exit 0
