#!/usr/bin/env bats
# ragnarok-stream/umu/autotype-login.sh with stub ydotool / xdotool / pgrep.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    A="$REPO/ragnarok-stream/umu/autotype-login.sh"
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    export RO_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
    export CALLS="$BATS_TEST_TMPDIR/calls"
    : >"$CALLS"
    export RO_LOGIN_FILE="$BATS_TEST_TMPDIR/login"
    printf 'brno\nsup3rsecret\n' >"$RO_LOGIN_FILE"
    chmod 600 "$RO_LOGIN_FILE"
    export YDOTOOL_SOCKET="$BATS_TEST_TMPDIR/ydotool.sock"
    touch "$YDOTOOL_SOCKET"
    export RO_TYPE_POLL=0.1 RO_LOGIN_DELAY=0.2 RO_TYPE_TIMEOUT=1

    # ydotool: argv and stdin recorded separately
    export YDOTOOL="$BATS_TEST_TMPDIR/ydotool"
    cat >"$YDOTOOL" <<'EOF'
#!/usr/bin/env bash
echo "ydotool socket=${YDOTOOL_SOCKET:-} $*" >>"$CALLS.argv"
if [ "${1:-}" = type ]; then cat >>"$CALLS.stdin"; fi
EOF
    # xdotool: `getactivewindow getwindowname` prints line N of $XD_SEQ (the last line repeats)
    export XDOTOOL="$BATS_TEST_TMPDIR/xdotool"
    export XD_SEQ="$BATS_TEST_TMPDIR/xd_seq" XD_N="$BATS_TEST_TMPDIR/xd_n"
    echo 0 >"$XD_N"
    cat >"$XDOTOOL" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$XD_N"); total=$(wc -l <"$XD_SEQ")
idx=$((n + 1)); [ "$idx" -gt "$total" ] && idx=$total
echo $((n + 1)) >"$XD_N"
line=$(sed -n "${idx}p" "$XD_SEQ")
[ "$line" = FAIL ] && exit 1
echo "$line"
EOF
    export PGREP="$BATS_TEST_TMPDIR/pgrep"
    printf '#!/usr/bin/env bash\n[ ! -e "$BATS_TEST_TMPDIR/nogame" ]\n' >"$PGREP"
    chmod +x "$YDOTOOL" "$XDOTOOL" "$PGREP"
}

windows() { printf '%s\n' "$@" >"$XD_SEQ"; }

@test "types the password ONLY via stdin (never argv), then Enter (28:1 28:0), once" {
    windows Ragnarok
    run "$A"
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS.stdin")" = sup3rsecret ]
    grep -q 'ydotool socket=.* type -d 40 -H 20 -f -' "$CALLS.argv"
    ! grep -q sup3rsecret "$CALLS.argv"
    [ "$(grep -c ' type ' "$CALLS.argv")" -eq 1 ]
    last=$(tail -n1 "$CALLS.argv")
    [[ "$last" == *"key 28:1 28:0" ]]
    [[ "$output" != *sup3rsecret* ]]
    [[ "$output" == *"typed 11 chars"* ]]
    [ ! -e "$RO_BACKUP_DIR/LAST_ERRORS" ]
}

@test "the socket env is passed to ydotool (default under XDG_RUNTIME_DIR)" {
    windows Ragnarok
    unset YDOTOOL_SOCKET
    XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" run "$A"
    # no socket there: refuses to type
    [ ! -e "$CALLS.argv" ]
    mkdir -p "$BATS_TEST_TMPDIR/run" && touch "$BATS_TEST_TMPDIR/run/.ydotool_socket"
    XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" run "$A"
    grep -q "socket=$BATS_TEST_TMPDIR/run/.ydotool_socket type" "$CALLS.argv"
}

@test "active window not Ragnarok at the re-check -> nothing typed, error recorded" {
    windows Ragnarok "Mozilla Firefox"
    run "$A"
    [ "$status" -eq 0 ]
    [ ! -e "$CALLS.argv" ]
    grep -q 'auto-login skipped: Ragnarok window not active' "$RO_BACKUP_DIR/LAST_ERRORS"
}

@test "the window becomes active after a few polls -> typed once" {
    windows "Mozilla Firefox" "Mozilla Firefox" FAIL Ragnarok
    run "$A"
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS.stdin")" = sup3rsecret ]
    [ "$(grep -c ' type ' "$CALLS.argv")" -eq 1 ]
}

@test "timeout (window never Ragnarok) -> nothing typed, error recorded" {
    windows "Mozilla Firefox"
    run "$A"
    [ "$status" -eq 0 ]
    [ ! -e "$CALLS.argv" ]
    grep -q 'auto-login skipped: Ragnarok window not active' "$RO_BACKUP_DIR/LAST_ERRORS"
}

@test "no Ragexe process -> never types, even if a window is called Ragnarok" {
    windows Ragnarok
    touch "$BATS_TEST_TMPDIR/nogame"
    run "$A"
    [ ! -e "$CALLS.argv" ]
    [ -s "$RO_BACKUP_DIR/LAST_ERRORS" ]
}

@test "invalid login file (644) -> nothing typed" {
    windows Ragnarok
    chmod 644 "$RO_LOGIN_FILE"
    run "$A"
    [ "$status" -eq 0 ]
    [ ! -e "$CALLS.argv" ]
    [[ "$output" != *sup3rsecret* ]]
}

@test "the password is not in the helper's env or argv listing (read from the file itself)" {
    windows Ragnarok
    env | grep -q sup3rsecret && false || true
    run "$A"
    ! grep -q sup3rsecret "$CALLS.argv"
}
