#!/usr/bin/env bats
# ragnarok-stream/sunshine/{prep,undo}.sh with stub busctl / brightnessctl / systemd-inhibit.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    PREP="$REPO/ragnarok-stream/sunshine/prep.sh"
    UNDO="$REPO/ragnarok-stream/sunshine/undo.sh"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    export RO_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
    export BRIGHT="$BATS_TEST_TMPDIR/bright" # the fake panel's current value
    export CALLS="$BATS_TEST_TMPDIR/calls"
    : >"$CALLS"
    export BUSCTL="$BIN/busctl" BRIGHTNESSCTL="$BIN/brightnessctl" SYSTEMD_INHIBIT="$BIN/systemd-inhibit"
    echo 40000 >"$BRIGHT"
}

teardown() {
    # kill any stub inhibitor still around
    local pid
    pid=$(cat "$STATE_DIR/inhibit.pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -- "-$pid" 2>/dev/null || true
    return 0
}

# busctl stub: Plasma 6 service (org.kde.ScreenBrightness) with one internal display.
stub_plasma6() {
    cat >"$BUSCTL" <<'EOF'
#!/usr/bin/env bash
echo "busctl $*" >>"$CALLS"
case "$2 $3" in
"get-property org.kde.ScreenBrightness")
    case "$6" in
    DisplaysDBusNames) echo 'as 2 "display1" "display0"' ;;
    IsInternal) [ "${4##*/}" = display0 ] && echo "b true" || echo "b false" ;;
    Brightness) echo "i $(cat "$BRIGHT")" ;;
    esac ;;
"call org.kde.ScreenBrightness")
    [ "$6" = SetBrightness ] && [ "$7" = iu ] && echo "$8" >"$BRIGHT" && [ "${4##*/}" = display0 ] ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$BUSCTL"
}

# busctl stub: only the old powerdevil service answers.
stub_legacy() {
    cat >"$BUSCTL" <<'EOF'
#!/usr/bin/env bash
echo "busctl $*" >>"$CALLS"
[ "$3" = org.kde.Solid.PowerManagement ] || exit 1
case "$6" in
brightness) echo "i $(cat "$BRIGHT")" ;;
setBrightness) echo "$8" >"$BRIGHT" ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$BUSCTL"
}

stub_busctl_dead() {
    printf '#!/usr/bin/env bash\nexit 1\n' >"$BUSCTL"
    chmod +x "$BUSCTL"
}

stub_brightnessctl() {
    cat >"$BRIGHTNESSCTL" <<'EOF'
#!/usr/bin/env bash
echo "brightnessctl $*" >>"$CALLS"
case "$*" in
*" g") cat "$BRIGHT" ;;
*" set "*) echo "${@: -1}" >"$BRIGHT" ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$BRIGHTNESSCTL"
}

stub_inhibit() {
    cat >"$SYSTEMD_INHIBIT" <<'EOF'
#!/usr/bin/env bash
echo "inhibit $*" >>"$CALLS"
sleep 300 &
wait
EOF
    chmod +x "$SYSTEMD_INHIBIT"
}

alive() { [ -r "/proc/$1/cmdline" ] && [ -n "$(tr -d '\0' <"/proc/$1/cmdline")" ]; }

@test "prep saves brightness and sets the minimum non-zero via Plasma 6" {
    stub_plasma6 && stub_inhibit
    run "$PREP"
    [ "$status" -eq 0 ]
    [ "$(cat "$BRIGHT")" = 1 ]
    grep -q '40000' "$STATE_DIR/brightness"
    grep -q 'org.kde.ScreenBrightness' "$CALLS"
}

@test "undo restores the Plasma 6 brightness and removes the state" {
    stub_plasma6 && stub_inhibit
    "$PREP"
    run "$UNDO"
    [ "$status" -eq 0 ]
    [ "$(cat "$BRIGHT")" = 40000 ]
    [ ! -e "$STATE_DIR/brightness" ]
}

@test "falls back to the legacy powerdevil service" {
    stub_legacy && stub_inhibit
    run "$PREP"
    [ "$status" -eq 0 ]
    [ "$(cat "$BRIGHT")" = 1 ]
    "$UNDO"
    [ "$(cat "$BRIGHT")" = 40000 ]
}

@test "falls back to brightnessctl" {
    stub_busctl_dead && stub_brightnessctl && stub_inhibit
    run "$PREP"
    [ "$status" -eq 0 ]
    [ "$(cat "$BRIGHT")" = 1 ]
    run "$UNDO"
    [ "$status" -eq 0 ]
    [ "$(cat "$BRIGHT")" = 40000 ]
    [ ! -e "$STATE_DIR/brightness" ]
}

@test "no backend: warns, still exits 0, still starts the inhibitor" {
    stub_busctl_dead && stub_inhibit
    export BRIGHTNESSCTL="$BIN/does-not-exist"
    run "$PREP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning"* ]]
    [ ! -e "$STATE_DIR/brightness" ]
    [ -s "$STATE_DIR/inhibit.pid" ]
    run "$UNDO"
    [ "$status" -eq 0 ]
}

@test "double prep keeps the original brightness" {
    stub_plasma6 && stub_inhibit
    "$PREP"
    run "$PREP"
    [ "$status" -eq 0 ]
    grep -q '40000' "$STATE_DIR/brightness"
    "$UNDO"
    [ "$(cat "$BRIGHT")" = 40000 ]
}

@test "undo with nothing saved is a no-op" {
    stub_plasma6
    run "$UNDO"
    [ "$status" -eq 0 ]
    [ "$(cat "$BRIGHT")" = 40000 ]
    [ ! -e "$STATE_DIR/brightness" ]
}

@test "inhibitor starts once and is killed by undo" {
    stub_plasma6 && stub_inhibit
    "$PREP"
    pid=$(cat "$STATE_DIR/inhibit.pid")
    alive "$pid"
    "$PREP"
    [ "$(cat "$STATE_DIR/inhibit.pid")" = "$pid" ]
    [ "$(grep -c '^inhibit ' "$CALLS")" -eq 1 ]
    grep -q -- '--what=idle:sleep --who=ragnarok-stream --why=Sunshine stream' "$CALLS"
    run "$UNDO"
    [ "$status" -eq 0 ]
    sleep 0.3
    ! alive "$pid"
    [ ! -e "$STATE_DIR/inhibit.pid" ]
}

@test "undo does not kill an unrelated process that reused the stored PID" {
    stub_plasma6
    sleep 60 &
    other=$!
    mkdir -p "$STATE_DIR"
    echo "$other" >"$STATE_DIR/inhibit.pid"
    run "$UNDO"
    [ "$status" -eq 0 ]
    alive "$other"
    kill "$other"
    [ ! -e "$STATE_DIR/inhibit.pid" ]
}

@test "undo: a real brightness restore failure is recorded in LAST_ERRORS, still exit 0" {
    stub_busctl_dead
    mkdir -p "$STATE_DIR"
    echo "plasma6 display0 40000" >"$STATE_DIR/brightness"
    run "$UNDO"
    [ "$status" -eq 0 ]
    grep -q 'undo.sh' "$RO_BACKUP_DIR/LAST_ERRORS"
}

@test "undo: nothing to do leaves no LAST_ERRORS" {
    stub_plasma6
    run "$UNDO"
    [ ! -e "$RO_BACKUP_DIR/LAST_ERRORS" ]
}

# busctl stub: after vmon-stop KDE exposes the internal panel under a NEW object name (display1 only)
stub_plasma6_renamed() {
    cat >"$BUSCTL" <<'EOF'
#!/usr/bin/env bash
echo "busctl $*" >>"$CALLS"
case "$2 $3" in
"get-property org.kde.ScreenBrightness")
    case "$6" in
    DisplaysDBusNames) echo 'as 1 "display1"' ;;
    IsInternal) [ "${4##*/}" = display1 ] && echo "b true" || exit 1 ;;
    Brightness) [ "${4##*/}" = display1 ] && echo "i $(cat "$BRIGHT")" || exit 1 ;;
    esac ;;
"call org.kde.ScreenBrightness")
    [ "${4##*/}" = display1 ] && [ "$6" = SetBrightness ] && echo "$8" >"$BRIGHT" ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$BUSCTL"
}

@test "undo: the saved display object vanished (re-enabled as display1) -> falls back to the internal one" {
    stub_plasma6_renamed
    echo 1 >"$BRIGHT"
    mkdir -p "$STATE_DIR"
    echo "plasma6 display0 10000" >"$STATE_DIR/brightness"
    run "$UNDO"
    [ "$status" -eq 0 ]
    [ "$(cat "$BRIGHT")" = 10000 ]
    [ ! -e "$RO_BACKUP_DIR/LAST_ERRORS" ]
    [ ! -e "$STATE_DIR/brightness" ]
}

@test "undo: still records an error when no internal display can be found either" {
    stub_busctl_dead
    mkdir -p "$STATE_DIR"
    echo "plasma6 display0 10000" >"$STATE_DIR/brightness"
    run "$UNDO"
    [ "$status" -eq 0 ]
    grep -q 'undo.sh' "$RO_BACKUP_DIR/LAST_ERRORS"
}
