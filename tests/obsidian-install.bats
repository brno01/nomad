#!/usr/bin/env bats
# scripts/obsidian-install.sh against a temp unit dir, without systemctl or the export.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    export UNIT_DIR="$BATS_TEST_TMPDIR/units" SKIP_SYSTEMCTL=1 SKIP_EXPORT=1 UV=/opt/fake/uv
}

@test "writes service and timer; second run changes nothing" {
    run "$REPO/scripts/obsidian-install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wrote   $UNIT_DIR/nomad-obsidian.service"* ]]
    grep -q "ExecStart=/opt/fake/uv run --no-project python -I $REPO/obsidian/export_nomad.py" "$UNIT_DIR/nomad-obsidian.service"
    grep -q "OnUnitActiveSec=10min" "$UNIT_DIR/nomad-obsidian.timer"
    run "$REPO/scripts/obsidian-install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"wrote"* ]]
}

@test "--dry-run writes nothing; --undo removes everything" {
    run "$REPO/scripts/obsidian-install.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would write"* ]]
    [ ! -e "$UNIT_DIR/nomad-obsidian.service" ]
    "$REPO/scripts/obsidian-install.sh"
    run "$REPO/scripts/obsidian-install.sh" --undo
    [ "$status" -eq 0 ]
    [ ! -e "$UNIT_DIR/nomad-obsidian.service" ]
    [ ! -e "$UNIT_DIR/nomad-obsidian.timer" ]
}

@test "rejects unknown arguments" {
    run "$REPO/scripts/obsidian-install.sh" --bogus
    [ "$status" -eq 2 ]
}
