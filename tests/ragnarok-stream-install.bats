#!/usr/bin/env bats
# scripts/ragnarok-stream-install.sh with a stub flatpak / umu-run and temp Sunshine, systemd and prefix dirs.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    INST="$REPO/scripts/ragnarok-stream-install.sh"
    export SUNSHINE_APPS="$BATS_TEST_TMPDIR/apps.json" SUNSHINE_CONF="$BATS_TEST_TMPDIR/sunshine.conf"
    export UNIT_DIR="$BATS_TEST_TMPDIR/units" SKIP_SYSTEMCTL=1
    export RO_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
    export RO_LOGIN_FILE="$BATS_TEST_TMPDIR/nologin"
    export CALLS="$BATS_TEST_TMPDIR/calls"
    : >"$CALLS"
    export SUNSHINE_BIN="$BATS_TEST_TMPDIR/sunshine-bin" GETCAP="$BATS_TEST_TMPDIR/getcap"
    touch "$SUNSHINE_BIN"
    printf '#!/usr/bin/env bash\n' >"$GETCAP"
    chmod +x "$GETCAP"
    export RO_DIR="$BATS_TEST_TMPDIR/RO"
    mkdir -p "$RO_DIR/fonts"
    echo font >"$RO_DIR/fonts/NanumGothic-Regular.ttf"
    export RO_PREFIX="$BATS_TEST_TMPDIR/pfx"
    export INSTALLED="$BATS_TEST_TMPDIR/amx-installed"
    export FLATPAK="$BATS_TEST_TMPDIR/flatpak"
    cat >"$FLATPAK" <<'EOF'
#!/usr/bin/env bash
echo "flatpak $*" >>"$CALLS"
case "$1" in
info) [ -e "$INSTALLED" ]; exit $? ;;
install) touch "$INSTALLED" ;;
esac
exit 0
EOF
    chmod +x "$FLATPAK"
    export UMU_RUN="$BATS_TEST_TMPDIR/umu-run"
    cat >"$UMU_RUN" <<'EOF'
#!/usr/bin/env bash
echo "umu $*" >>"$CALLS"
case "$1 $2" in
"regedit /S") cp "$3" "$CALLS.reg" ;;
"reg query") [ -e "$CALLS.reg" ] && echo "Gulim NanumGothic" ;;
esac
exit 0
EOF
    chmod +x "$UMU_RUN"
    DROPIN_REL=app-dev.lizardbyte.app.Sunshine.service.d/10-nomad-enhancement.conf
}

bootstrapped() { mkdir -p "$RO_PREFIX/drive_c/windows" && echo REG >"$RO_PREFIX/system.reg"; }

@test "rejects unknown arguments" {
    run "$INST" --bogus
    [ "$status" -eq 2 ]
}

@test "no Steam steps any more: no layout, shortcut or xbox support" {
    run "$INST"
    [ "$status" -eq 0 ]
    [[ "$output" != *shortcut* ]]
    [[ "$output" != *"Steam Input"* ]]
    ! grep -q 'add_shortcut\|enable_xbox\|uv ' "$CALLS"
}

@test "--dry-run touches nothing" {
    run "$INST" --dry-run
    [ "$status" -eq 0 ]
    [ ! -e "$SUNSHINE_APPS" ]
    [ ! -e "$SUNSHINE_CONF" ]
    [ ! -e "$UNIT_DIR/$DROPIN_REL" ]
    [ ! -e "$INSTALLED" ]
    ! grep -q 'flatpak install\|flatpak remote-add' "$CALLS"
    [[ "$output" == *"would"* ]]
}

@test "apply: drop-in, AntiMicroX (user flathub), Sunshine app and conf" {
    run "$INST"
    [ "$status" -eq 0 ]
    cmp "$REPO/ragnarok-stream/sunshine/10-nomad-enhancement.conf" "$UNIT_DIR/$DROPIN_REL"
    grep -q 'flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo' "$CALLS"
    grep -q 'flatpak install --user -y --noninteractive flathub io.github.antimicrox.antimicrox' "$CALLS"
    jq -e --arg r "$REPO" '.apps[] | select(.name=="Ragnarok") | .cmd == $r + "/ragnarok-stream/umu/launch.sh"' "$SUNSHINE_APPS"
    grep -qx 'capture = kwin' "$SUNSHINE_CONF"
}

@test "AntiMicroX already installed (user or system): nothing is installed" {
    touch "$INSTALLED"
    run "$INST"
    [ "$status" -eq 0 ]
    ! grep -q 'flatpak install\|flatpak remote-add' "$CALLS"
}

@test "idempotent: a second run changes nothing and installs nothing again" {
    "$INST"
    : >"$CALLS"
    run "$INST"
    [ "$status" -eq 0 ]
    [[ "$output" != *"wrote "* ]]
    ! grep -q 'flatpak install' "$CALLS"
}

@test "missing flatpak: clear error, non-zero" {
    FLATPAK=/nonexistent run "$INST"
    [ "$status" -ne 0 ]
    [[ "$output" == *"flatpak"* ]]
}

@test "prefix not bootstrapped: says to run bootstrap.sh and skips the fonts" {
    run "$INST"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bootstrap.sh"* ]]
    ! grep -q 'regedit' "$CALLS"
}

@test "prefix bootstrapped: fonts are set up" {
    bootstrapped
    run "$INST"
    [ "$status" -eq 0 ]
    grep -q 'regedit /S' "$CALLS"
    [ -e "$RO_PREFIX/.ragnarok-fonts-v1" ]
}

@test "--skip flags" {
    run "$INST" --skip-antimicrox --skip-sunshine --skip-prefix
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
    [ ! -e "$SUNSHINE_APPS" ]
}

@test "--undo removes app, conf keys and drop-in; keeps AntiMicroX and the prefix" {
    printf 'foo = bar\n' >"$SUNSHINE_CONF"
    bootstrapped
    "$INST"
    run "$INST" --undo
    [ "$status" -eq 0 ]
    [ ! -e "$UNIT_DIR/$DROPIN_REL" ]
    [ "$(jq '.apps | length' "$SUNSHINE_APPS")" -eq 0 ]
    [ "$(cat "$SUNSHINE_CONF")" = "foo = bar" ]
    [ -e "$INSTALLED" ]
    [ -d "$RO_PREFIX" ]
    ! grep -q 'flatpak uninstall' "$CALLS"
    [[ "$output" == *"flatpak uninstall"* ]]
    [[ "$output" == *"$RO_PREFIX"* ]]
}

@test "--check reports missing pieces with non-zero, everything ok with zero" {
    run "$INST" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing"* ]]
    bootstrapped
    "$INST"
    run "$INST" --check
    [ "$status" -eq 0 ]
}

@test "--check fails when the committed profile is stale" {
    "$INST"
    export RO_AMGP_DIR="$BATS_TEST_TMPDIR/amgp"
    mkdir -p "$RO_AMGP_DIR"
    echo "<stale/>" >"$RO_AMGP_DIR/ragnarok.amgp"
    run "$INST" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"profile"* ]]
}

@test "--check fails on file capabilities and prints the sudo setcap fix" {
    bootstrapped
    "$INST"
    printf '#!/usr/bin/env bash\necho "$1 cap_sys_admin,cap_sys_nice=p"\n' >"$GETCAP"
    run "$INST" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo setcap -r $SUNSHINE_BIN"* ]]
}

@test "--check fails when LAST_ERRORS exists, showing its tail and how to clear it" {
    bootstrapped
    "$INST"
    mkdir -p "$RO_BACKUP_DIR"
    echo "2026-11-16T10:00:00 ro-resolution.sh: boom" >"$RO_BACKUP_DIR/LAST_ERRORS"
    run "$INST" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"boom"* ]]
    [[ "$output" == *"rm $RO_BACKUP_DIR/LAST_ERRORS"* ]]
}

@test "paths derive from the script location (a copy elsewhere uses its own checkout)" {
    copy="$BATS_TEST_TMPDIR/deployed"
    mkdir -p "$copy"
    cp -r "$REPO/scripts" "$REPO/ragnarok-stream" "$copy/"
    run "$copy/scripts/ragnarok-stream-install.sh"
    [ "$status" -eq 0 ]
    jq -e --arg r "$copy" '.apps[] | select(.name=="Ragnarok") | .cmd == $r + "/ragnarok-stream/umu/launch.sh"' "$SUNSHINE_APPS"
}

@test "--no-spring and --spring are gone" {
    run "$INST" --no-spring
    [ "$status" -eq 2 ]
    run "$INST" --spring
    [ "$status" -eq 2 ]
}

@test "the single committed profile is checked" {
    "$INST"
    export RO_AMGP_DIR="$BATS_TEST_TMPDIR/amgp"
    mkdir -p "$RO_AMGP_DIR"
    cp "$REPO/ragnarok-stream/antimicrox/ragnarok.amgp" "$RO_AMGP_DIR/"
    bootstrapped
    "$INST"
    run "$INST" --check
    [ "$status" -eq 0 ]
}

@test "--check: login file absent is informational, valid needs ydotool socket and xdotool, bad permissions fail" {
    bootstrapped
    "$INST"
    run "$INST" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"login"*"absent"* ]]
    export RO_LOGIN_FILE="$BATS_TEST_TMPDIR/login"
    printf 'user\nsecret\n' >"$RO_LOGIN_FILE"
    chmod 600 "$RO_LOGIN_FILE"
    # valid file but no socket / tools -> failure
    export YDOTOOL_SOCKET="$BATS_TEST_TMPDIR/ydotool.sock" YDOTOOL="$BATS_TEST_TMPDIR/ydotool" XDOTOOL="$BATS_TEST_TMPDIR/xdotool"
    run "$INST" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"ydotool socket missing"* ]]
    touch "$YDOTOOL_SOCKET" && printf '#!/usr/bin/env bash\n' >"$YDOTOOL" && chmod +x "$YDOTOOL"
    run "$INST" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"xdotool not found"* ]]
    printf '#!/usr/bin/env bash\n' >"$XDOTOOL" && chmod +x "$XDOTOOL"
    run "$INST" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"login file"*"valid"* ]]
    [[ "$output" != *secret* ]]
    chmod 644 "$RO_LOGIN_FILE"
    run "$INST" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"chmod 600"* ]]
    [[ "$output" != *secret* ]]
}
