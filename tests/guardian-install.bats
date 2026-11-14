#!/usr/bin/env bats
# scripts/guardian-install.sh against a temp unit dir, without systemctl.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    export UNIT_DIR="$BATS_TEST_TMPDIR/units" SKIP_SYSTEMCTL=1 UV=/opt/fake/uv
}

@test "writes the service; second run changes nothing" {
    run "$REPO/scripts/guardian-install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wrote   $UNIT_DIR/nomad-obsidian-guardian.service"* ]]
    grep -q "ExecStart=/opt/fake/uv run --no-project python -I $REPO/obsidian/guardian.py" "$UNIT_DIR/nomad-obsidian-guardian.service"
    grep -q "Restart=always" "$UNIT_DIR/nomad-obsidian-guardian.service"
    run "$REPO/scripts/guardian-install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"wrote"* ]]
}

@test "--dry-run writes nothing; --undo removes the service and is safe to repeat" {
    run "$REPO/scripts/guardian-install.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would write"* ]]
    [ ! -e "$UNIT_DIR/nomad-obsidian-guardian.service" ]
    "$REPO/scripts/guardian-install.sh"
    run "$REPO/scripts/guardian-install.sh" --undo
    [ "$status" -eq 0 ]
    [ ! -e "$UNIT_DIR/nomad-obsidian-guardian.service" ]
    run "$REPO/scripts/guardian-install.sh" --undo
    [ "$status" -eq 0 ]
}

@test "rejects unknown arguments" {
    run "$REPO/scripts/guardian-install.sh" --bogus
    [ "$status" -eq 2 ]
}
