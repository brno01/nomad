#!/usr/bin/env bats

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    export NM_CONF_DIR="$BATS_TEST_TMPDIR/conf.d" SKIP_APPLY=1
    mkdir -p "$NM_CONF_DIR"
    CONF="$NM_CONF_DIR/90-nomad-wifi-powersave-off.conf"
}

@test "writes the NetworkManager drop-in with power save disabled" {
    run "$REPO/scripts/wifi-powersave.sh"
    [ "$status" -eq 0 ]
    grep -qx '\[connection\]' "$CONF"
    grep -qx 'wifi.powersave = 2' "$CONF"
}

@test "is idempotent: a second run changes nothing" {
    "$REPO/scripts/wifi-powersave.sh"
    before=$(md5sum "$CONF")
    run "$REPO/scripts/wifi-powersave.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok      $CONF"* ]]
    [ "$(md5sum "$CONF")" = "$before" ]
}

@test "--dry-run writes nothing" {
    run "$REPO/scripts/wifi-powersave.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would write"* ]]
    [ ! -e "$CONF" ]
}

@test "--undo removes the drop-in and is safe to repeat" {
    "$REPO/scripts/wifi-powersave.sh"
    run "$REPO/scripts/wifi-powersave.sh" --undo
    [ "$status" -eq 0 ]
    [ ! -e "$CONF" ]
    run "$REPO/scripts/wifi-powersave.sh" --undo
    [ "$status" -eq 0 ]
    [[ "$output" == *"already absent"* ]]
}

@test "rejects unknown arguments" {
    run "$REPO/scripts/wifi-powersave.sh" --bogus
    [ "$status" -eq 2 ]
}
