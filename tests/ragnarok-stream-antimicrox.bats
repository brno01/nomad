#!/usr/bin/env bats
# ragnarok-stream/sunshine/antimicrox-{start,stop}.sh with a stub flatpak and a fake /proc/bus/input/devices.
# start launches a detached watcher; the watcher (re)starts AntiMicroX whenever the Sunshine pad appears.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    S="$REPO/ragnarok-stream/sunshine"
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    export RO_BACKUP_DIR="$BATS_TEST_TMPDIR/backup"
    export CALLS="$BATS_TEST_TMPDIR/calls"
    : >"$CALLS"
    export FLATPAK="$BATS_TEST_TMPDIR/flatpak"
    cat >"$FLATPAK" <<'EOF'
#!/usr/bin/env bash
echo "flatpak $*" >>"$CALLS"
sleep 300 &
wait
EOF
    chmod +x "$FLATPAK"
    export INPUT_DEVICES="$BATS_TEST_TMPDIR/devices"
    export WATCH_POLL=0.1
    cat >"$INPUT_DEVICES" <<'EOF'
I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
H: Handlers=sysrq kbd event3 leds

EOF
}

teardown() {
    local f pid
    for f in antimicrox.pid antimicrox-watch.pid; do
        pid=$(cat "$STATE_DIR/$f" 2>/dev/null || true)
        if [ -n "$pid" ]; then kill -- "-$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; fi
    done
    return 0
}

alive() { [ -r "/proc/$1/cmdline" ] && [ -n "$(tr -d '\0' <"/proc/$1/cmdline")" ]; }
flatpak_runs() { grep -c '^flatpak ' "$CALLS" || true; }
wait_until() { # wait_until <seconds> <command...>
    local t=$1 i
    shift
    for ((i = 0; i < t * 10; i++)); do
        "$@" && return 0
        sleep 0.1
    done
    return 1
}
runs_are() { [ "$(flatpak_runs)" -eq "$1" ]; }

# set the fake devices file to a Sunshine pad exposed as eventN
set_pad() {
    cat >"$INPUT_DEVICES" <<EOF
I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
H: Handlers=sysrq kbd event3 leds

I: Bus=0003 Vendor=045e Product=028e Version=0114
N: Name="Microsoft X-Box 360 pad"
H: Handlers=js0 event$1

EOF
}
no_pad() { printf 'N: Name="AT Translated Set 2 keyboard"\nH: Handlers=sysrq kbd event3 leds\n\n' >"$INPUT_DEVICES"; }

@test "start launches only a watcher: no AntiMicroX until the pad exists" {
    run "$S/antimicrox-start.sh"
    [ "$status" -eq 0 ]
    wpid=$(cat "$STATE_DIR/antimicrox-watch.pid")
    alive "$wpid"
    sleep 0.6
    runs_are 0
    [ ! -e "$STATE_DIR/antimicrox.pid" ]
}

@test "a pad appearing starts AntiMicroX with hidden, uinput and our profile" {
    "$S/antimicrox-start.sh"
    sleep 0.3
    set_pad 20
    wait_until 5 runs_are 1
    line=$(grep '^flatpak ' "$CALLS")
    [[ "$line" == *"run "* ]]
    [[ "$line" == *"io.github.antimicrox.antimicrox"* ]]
    [[ "$line" == *"--hidden"* ]]
    [[ "$line" == *"--eventgen uinput"* ]]
    [[ "$line" == *"--profile $REPO/ragnarok-stream/antimicrox/ragnarok.amgp"* ]]
    [[ "$line" == *"--filesystem=$REPO/ragnarok-stream/antimicrox:ro"* ]]
    pid=$(cat "$STATE_DIR/antimicrox.pid")
    alive "$pid"
}

@test "the same pad set does not restart AntiMicroX" {
    set_pad 20
    "$S/antimicrox-start.sh"
    wait_until 5 runs_are 1
    sleep 0.8
    runs_are 1
}

@test "the pad re-created with a new eventN restarts AntiMicroX (old instance stopped)" {
    set_pad 20
    "$S/antimicrox-start.sh"
    wait_until 5 runs_are 1
    old=$(cat "$STATE_DIR/antimicrox.pid")
    no_pad
    sleep 0.4
    set_pad 21
    wait_until 5 runs_are 2
    new=$(cat "$STATE_DIR/antimicrox.pid")
    [ "$new" != "$old" ]
    wait_until 3 bash -c "! [ -r /proc/$old/cmdline ] || [ -z \"\$(tr -d '\\0' </proc/$old/cmdline)\" ]"
    alive "$new"
}

@test "a pad re-created with the SAME eventN after disappearing also restarts" {
    set_pad 20
    "$S/antimicrox-start.sh"
    wait_until 5 runs_are 1
    no_pad
    sleep 0.4
    set_pad 20
    wait_until 5 runs_are 2
}

@test "SUNSHINE_PAD_PATTERN selects which devices count" {
    printf 'N: Name="My Custom Pad"\nH: Handlers=js0 event30\n\n' >"$INPUT_DEVICES"
    SUNSHINE_PAD_PATTERN='Custom Pad' "$S/antimicrox-start.sh"
    wait_until 5 runs_are 1
}

@test "start twice does not start a second watcher" {
    "$S/antimicrox-start.sh"
    pid=$(cat "$STATE_DIR/antimicrox-watch.pid")
    run "$S/antimicrox-start.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE_DIR/antimicrox-watch.pid")" = "$pid" ]
}

@test "stop kills the watcher and our AntiMicroX, and removes both pid files" {
    set_pad 20
    "$S/antimicrox-start.sh"
    wait_until 5 runs_are 1
    wpid=$(cat "$STATE_DIR/antimicrox-watch.pid")
    apid=$(cat "$STATE_DIR/antimicrox.pid")
    run "$S/antimicrox-stop.sh"
    [ "$status" -eq 0 ]
    sleep 0.4
    ! alive "$wpid"
    ! alive "$apid"
    [ ! -e "$STATE_DIR/antimicrox.pid" ]
    [ ! -e "$STATE_DIR/antimicrox-watch.pid" ]
    set_pad 22
    sleep 0.5
    runs_are 1 # the dead watcher did not start anything new
}

@test "stop does not kill unrelated processes that reused the pids" {
    sleep 60 &
    other=$!
    sleep 60 &
    other2=$!
    mkdir -p "$STATE_DIR"
    echo "$other" >"$STATE_DIR/antimicrox.pid"
    echo "$other2" >"$STATE_DIR/antimicrox-watch.pid"
    run "$S/antimicrox-stop.sh"
    [ "$status" -eq 0 ]
    alive "$other"
    alive "$other2"
    kill "$other" "$other2"
    [ ! -e "$STATE_DIR/antimicrox.pid" ]
}

@test "stop with nothing running is a no-op" {
    run "$S/antimicrox-stop.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$RO_BACKUP_DIR/LAST_ERRORS" ]
}

@test "start failures exit 0 and are recorded (no flatpak, no profile)" {
    FLATPAK=/nonexistent run "$S/antimicrox-start.sh"
    [ "$status" -eq 0 ]
    grep -q 'antimicrox-start.sh' "$RO_BACKUP_DIR/LAST_ERRORS"
    : >"$RO_BACKUP_DIR/LAST_ERRORS"
    RO_AMGP=/nonexistent.amgp run "$S/antimicrox-start.sh"
    [ "$status" -eq 0 ]
    grep -q 'profile' "$RO_BACKUP_DIR/LAST_ERRORS"
    [ ! -e "$STATE_DIR/antimicrox-watch.pid" ]
}

