#!/usr/bin/env bash
# One-time font setup of the umu prefix: copy NanumGothic into the prefix and import, in ONE .reg
# import, the same registry entries as iniciar-cerberus.sh (font link for Korean fallback,
# Gulim/Dotum/Batang replacements, DirectSound emulation).
#
# Usage: setup-prefix.sh [--dry-run]       Exit 3 = prefix not bootstrapped yet (run bootstrap.sh first).
#
# Method: `umu-run regedit /S file.reg` with the same umu env as the game (so it uses the same Proton and
# prefix), then `umu-run wineboot -s` so the registry is flushed to disk. umu-run takes the program as its
# first argument and hands it to Proton's `run`, so a wine builtin such as regedit/wineboot/winecfg works
# (the umu docs show `umu-run winetricks ...`; plain `umu-run winecfg` is the usual idiom; not spelled out in the
# README). The result is verified with `umu-run reg query` before the marker is written.
# Idempotent: the marker $RO_PREFIX/.ragnarok-fonts-v1 skips it.
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

FONT=NanumGothic-Regular.ttf
MARK=$RO_PREFIX/.ragnarok-fonts-v1

if ! prefix_bootstrapped; then
    die "prefix $RO_PREFIX is not bootstrapped yet: run ragnarok-stream/umu/bootstrap.sh first and wait for it (first run downloads GBs)." 3
fi
if [ -e "$MARK" ]; then
    log "ok      fonts already set up in $RO_PREFIX"
    exit 0
fi
[ -f "$RO_DIR/fonts/$FONT" ] || die "font not found: $RO_DIR/fonts/$FONT"
if [ "$DRY" = 1 ]; then
    log "would copy $RO_DIR/fonts/$FONT to $RO_PREFIX/drive_c/windows/Fonts/"
    log "would import the font-link/replacement .reg with: umu-run regedit /S"
    exit 0
fi

multi_sz() { # REG_MULTI_SZ text -> hex(7) body (UTF-16LE + terminators)
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | od -An -v -tx1 | tr -d ' \n' | sed 's/../&,/g'
    printf '00,00,00,00'
}

mkdir -p "$RO_PREFIX/drive_c/windows/Fonts"
cp -f "$RO_DIR/fonts/$FONT" "$RO_PREFIX/drive_c/windows/Fonts/$FONT"

reg=$RO_PREFIX/ragnarok-fonts.reg
{
    printf 'Windows Registry Editor Version 5.00\n\n'
    printf '[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts]\n"NanumGothic (TrueType)"="%s"\n\n' "$FONT"
    printf '[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink]\n'
    for n in "Tahoma" "MS Shell Dlg" "MS Shell Dlg 2" "Microsoft Sans Serif" "Segoe UI" "Lucida Sans Unicode" "Arial" "Verdana"; do
        printf '"%s"=hex(7):%s\n' "$n" "$(multi_sz "$FONT,NanumGothic")"
    done
    printf '\n[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]\n"HardwareAcceleration"="Emulation"\n'
    printf '\n[HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements]\n'
    for n in "Gulim" "GulimChe" "Dotum" "DotumChe" "Batang" "BatangChe" "굴림" "굴림체" "돋움" "바탕"; do
        printf '"%s"="NanumGothic"\n' "$n"
    done
} | iconv -f UTF-8 -t UTF-16 >"$reg"

umu regedit /S "$reg" >/dev/null 2>&1 || true
umu wineboot -s >/dev/null 2>&1 || true
if umu reg query 'HKCU\Software\Wine\Fonts\Replacements' /v Gulim 2>/dev/null | grep -q NanumGothic; then
    touch "$MARK"
    rm -f "$reg"
    umu wineboot -s >/dev/null 2>&1 || true
    log "done    font and registry set up in $RO_PREFIX"
else
    die "could not write the font settings to the prefix registry (kept $reg); is the game still running?"
fi
