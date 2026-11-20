#!/usr/bin/env bats
# ragnarok-stream/sunshine/{vmon-start,vmon-stop,ro-resolution}.sh with stub Bazzite helpers and fixture files.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    S="$REPO/ragnarok-stream/sunshine"
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    export RO_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
    export CALLS="$BATS_TEST_TMPDIR/calls"
    : >"$CALLS"
    export VMON_START="$BATS_TEST_TMPDIR/start-vmon" VMON_STOP="$BATS_TEST_TMPDIR/stop-vmon"
    cat >"$VMON_START" <<'EOF'
#!/usr/bin/env bash
echo "start ${SUNSHINE_CLIENT_WIDTH}x${SUNSHINE_CLIENT_HEIGHT}@${SUNSHINE_CLIENT_FPS:-}" >>"$CALLS"
exit "${STUB_START_RC:-0}"
EOF
    cat >"$VMON_STOP" <<'EOF'
#!/usr/bin/env bash
echo "stop" >>"$CALLS"
exit "${STUB_STOP_RC:-0}"
EOF
    chmod +x "$VMON_START" "$VMON_STOP"
    export RO_OPTIONINFO="$BATS_TEST_TMPDIR/OptionInfo.lua"
    printf -- '-- options\r\nOptionInfoList = {}\r\nOptionInfoList["ISFULLSCREENMODE"] = 0\r\nOptionInfoList["WIDTH"] = 1280\r\nOptionInfoList["HEIGHT"] = 1024\r\nOptionInfoList["OLD_WIDTH"] = 1280\r\nOptionInfoList["OLD_HEIGHT"] = 1024\r\nOptionInfoList["VOLUME"] = 70\r\n' >"$RO_OPTIONINFO"
    cp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/orig"
}

# ---- vmon -------------------------------------------------------------

@test "vmon-start: S22+ 2340x1080 -> 1560x720 and records the size" {
    SUNSHINE_CLIENT_WIDTH=2340 SUNSHINE_CLIENT_HEIGHT=1080 SUNSHINE_CLIENT_FPS=60 run "$S/vmon-start.sh"
    [ "$status" -eq 0 ]
    grep -qx 'start 1560x720@60' "$CALLS"
    [ "$(cat "$STATE_DIR/stream-size")" = "1560 720" ]
}

@test "vmon-start: 16:9 client, and an odd ratio rounds to an even width" {
    SUNSHINE_CLIENT_WIDTH=1920 SUNSHINE_CLIENT_HEIGHT=1080 run "$S/vmon-start.sh"
    [ "$(cat "$STATE_DIR/stream-size")" = "1280 720" ]
    SUNSHINE_CLIENT_WIDTH=1001 SUNSHINE_CLIENT_HEIGHT=1080 run "$S/vmon-start.sh"
    read -r w _ <"$STATE_DIR/stream-size"
    [ $((w % 2)) -eq 0 ]
}

@test "vmon-start: client smaller than RO_STREAM_HEIGHT keeps the client height" {
    SUNSHINE_CLIENT_WIDTH=800 SUNSHINE_CLIENT_HEIGHT=480 run "$S/vmon-start.sh"
    grep -qx 'start 800x480@' "$CALLS"
}

@test "vmon-start: RO_STREAM_HEIGHT override and defaults without client vars" {
    RO_STREAM_HEIGHT=900 run "$S/vmon-start.sh"
    [ "$(cat "$STATE_DIR/stream-size")" = "1600 900" ]
}

@test "vmon-start: helper failure and missing helper propagate non-zero" {
    STUB_START_RC=7 run "$S/vmon-start.sh"
    [ "$status" -eq 7 ]
    VMON_START=/nonexistent run "$S/vmon-start.sh"
    [ "$status" -ne 0 ]
}

@test "vmon-start: when the helper fails it calls vmon-stop, drops the size file and keeps the code" {
    STUB_START_RC=7 run "$S/vmon-start.sh"
    [ "$status" -eq 7 ]
    grep -qx stop "$CALLS"
    [ ! -e "$STATE_DIR/stream-size" ]
}

@test "vmon-start: stop failure during cleanup does not change the exit code" {
    STUB_START_RC=5 STUB_STOP_RC=9 run "$S/vmon-start.sh"
    [ "$status" -eq 5 ]
}

@test "vmon-start: the height is rounded to even too" {
    SUNSHINE_CLIENT_WIDTH=1000 SUNSHINE_CLIENT_HEIGHT=481 run "$S/vmon-start.sh"
    read -r w h <"$STATE_DIR/stream-size"
    [ "$h" -eq 480 ]
    [ $((w % 2)) -eq 0 ]
    grep -q "start ${w}x480@" "$CALLS"
}

@test "vmon-stop: calls the helper, drops the size, always exits 0" {
    mkdir -p "$STATE_DIR" && echo "1560 720" >"$STATE_DIR/stream-size"
    STUB_STOP_RC=3 run "$S/vmon-stop.sh"
    [ "$status" -eq 0 ]
    grep -qx stop "$CALLS"
    [ ! -e "$STATE_DIR/stream-size" ]
    VMON_STOP=/nonexistent run "$S/vmon-stop.sh"
    [ "$status" -eq 0 ]
}

# ---- ro-resolution ----------------------------------------------------

size() { mkdir -p "$STATE_DIR" && echo "$1 $2" >"$STATE_DIR/stream-size"; }

@test "ro-resolution set: edits only the five display lines, rest byte-identical" {
    size 1560 720
    run "$S/ro-resolution.sh" set
    [ "$status" -eq 0 ]
    expected=$(printf -- '-- options\r\nOptionInfoList = {}\r\nOptionInfoList["ISFULLSCREENMODE"] = 1\r\nOptionInfoList["WIDTH"] = 1560\r\nOptionInfoList["HEIGHT"] = 720\r\nOptionInfoList["OLD_WIDTH"] = 1560\r\nOptionInfoList["OLD_HEIGHT"] = 720\r\nOptionInfoList["VOLUME"] = 70\r\n' | od -c)
    [ "$(od -c "$RO_OPTIONINFO")" = "$expected" ]
}

@test "ro-resolution: backup lives in the persistent backup dir, not next to the game" {
    size 1560 720
    "$S/ro-resolution.sh" set
    [ -s "$RO_BACKUP_DIR/optioninfo.saved" ]
    [ "$(ls "$BATS_TEST_TMPDIR" | grep -c -i 'OptionInfo.lua')" -eq 1 ]
}

@test "ro-resolution restore still works after a reboot wiped the volatile state dir" {
    size 1560 720
    "$S/ro-resolution.sh" set
    rm -rf "$STATE_DIR"
    run "$S/ro-resolution.sh" restore
    [ "$status" -eq 0 ]
    cmp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/orig"
}

@test "ro-resolution set twice then restore returns the original file" {
    size 1560 720
    "$S/ro-resolution.sh" set
    "$S/ro-resolution.sh" set
    run "$S/ro-resolution.sh" restore
    [ "$status" -eq 0 ]
    cmp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/orig"
    [ ! -e "$RO_BACKUP_DIR/optioninfo.saved" ]
}

@test "ro-resolution restore keeps options changed in-game during the stream" {
    size 1560 720
    "$S/ro-resolution.sh" set
    sed -i 's/\["VOLUME"\] = 70/["VOLUME"] = 20/' "$RO_OPTIONINFO"
    "$S/ro-resolution.sh" restore
    grep -q 'VOLUME"\] = 20' "$RO_OPTIONINFO"
    grep -q 'WIDTH"\] = 1280' "$RO_OPTIONINFO"
    grep -q 'ISFULLSCREENMODE"\] = 0' "$RO_OPTIONINFO"
}

@test "ro-resolution restore with nothing saved is a no-op" {
    run "$S/ro-resolution.sh" restore
    [ "$status" -eq 0 ]
    cmp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/orig"
}

@test "ro-resolution set without a size or without the file warns and exits 0" {
    run "$S/ro-resolution.sh" set
    [ "$status" -eq 0 ]
    [[ "$output" == *warning* ]]
    cmp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/orig"
    size 1560 720
    RO_OPTIONINFO=/nonexistent/x.lua run "$S/ro-resolution.sh" set
    [ "$status" -eq 0 ]
}

# ---- ro-resolution: game running, waiter, atomic write, errors ----------

setup_pgrep() {
    export RUNNING="$BATS_TEST_TMPDIR/running"
    export PGREP="$BATS_TEST_TMPDIR/pgrep"
    printf '#!/usr/bin/env bash\n[ -e "$RUNNING" ]\n' >"$PGREP"
    chmod +x "$PGREP"
    export RO_POLL=0.2
}

wait_until() { # wait_until <seconds> <command...>
    local t=$1 i
    shift
    for ((i = 0; i < t * 10; i++)); do
        "$@" && return 0
        sleep 0.1
    done
    return 1
}

teardown() {
    local pid
    pid=$(cat "$RO_BACKUP_DIR/waiter.pid" 2>/dev/null || true)
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    return 0
}

saved_gone() { [ ! -e "$RO_BACKUP_DIR/optioninfo.saved" ]; }

@test "restore while the game runs: file untouched, backup kept, one waiter started" {
    setup_pgrep
    size 1560 720
    "$S/ro-resolution.sh" set
    cp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/streamed"
    touch "$RUNNING"
    run "$S/ro-resolution.sh" restore
    [ "$status" -eq 0 ]
    cmp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/streamed"
    [ -s "$RO_BACKUP_DIR/optioninfo.saved" ]
    pid=$(cat "$RO_BACKUP_DIR/waiter.pid")
    grep -q ro-resolution "/proc/$pid/cmdline"
    "$S/ro-resolution.sh" restore
    [ "$(cat "$RO_BACKUP_DIR/waiter.pid")" = "$pid" ]
}

@test "the waiter restores once the game exits and clears its pid file" {
    setup_pgrep
    size 1560 720
    "$S/ro-resolution.sh" set
    touch "$RUNNING"
    "$S/ro-resolution.sh" restore
    sleep 0.5
    [ -s "$RO_BACKUP_DIR/optioninfo.saved" ]
    rm "$RUNNING"
    wait_until 5 saved_gone
    cmp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/orig"
    wait_until 2 test ! -e "$RO_BACKUP_DIR/waiter.pid"
}

@test "the waiter gives up at RO_WAIT_MAX, keeps the backup and records the error" {
    setup_pgrep
    size 1560 720
    "$S/ro-resolution.sh" set
    touch "$RUNNING"
    RO_WAIT_MAX=1 "$S/ro-resolution.sh" restore
    wait_until 6 test -s "$RO_BACKUP_DIR/LAST_ERRORS"
    [ -s "$RO_BACKUP_DIR/optioninfo.saved" ]
    grep -q 'ro-resolution' "$RO_BACKUP_DIR/LAST_ERRORS"
}

@test "a set while a backup is pending keeps the ORIGINAL values" {
    setup_pgrep
    size 1560 720
    "$S/ro-resolution.sh" set
    touch "$RUNNING"
    "$S/ro-resolution.sh" restore
    size 1000 480
    "$S/ro-resolution.sh" set
    rm "$RUNNING"
    wait_until 5 saved_gone
    cmp "$RO_OPTIONINFO" "$BATS_TEST_TMPDIR/orig"
}

@test "set writes in one pass: no temp files left, mode kept, orig copy saved byte-for-byte" {
    size 1560 720
    chmod 640 "$RO_OPTIONINFO"
    "$S/ro-resolution.sh" set
    [ "$(stat -c %a "$RO_OPTIONINFO")" = 640 ]
    [ -z "$(ls -A "$BATS_TEST_TMPDIR" | grep '^\.OptionInfo' || true)" ]
    cmp "$RO_BACKUP_DIR/optioninfo.orig.lua" "$BATS_TEST_TMPDIR/orig"
    "$S/ro-resolution.sh" set
    cmp "$RO_BACKUP_DIR/optioninfo.orig.lua" "$BATS_TEST_TMPDIR/orig"
    "$S/ro-resolution.sh" restore
    [ ! -e "$RO_BACKUP_DIR/optioninfo.orig.lua" ]
}

@test "restore failure (unwritable file) records LAST_ERRORS, keeps the backup, exits 0" {
    [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
    size 1560 720
    "$S/ro-resolution.sh" set
    chmod 444 "$RO_OPTIONINFO"
    run "$S/ro-resolution.sh" restore
    [ "$status" -eq 0 ]
    [ -s "$RO_BACKUP_DIR/LAST_ERRORS" ]
    [ -s "$RO_BACKUP_DIR/optioninfo.saved" ]
    chmod 644 "$RO_OPTIONINFO"
}
