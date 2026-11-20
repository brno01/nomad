#!/usr/bin/env bats
# ragnarok-stream/sunshine/install-app.sh against temp apps.json / sunshine.conf.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    IA="$REPO/ragnarok-stream/sunshine/install-app.sh"
    export SUNSHINE_APPS="$BATS_TEST_TMPDIR/apps.json" SUNSHINE_CONF="$BATS_TEST_TMPDIR/sunshine.conf"
    cat >"$SUNSHINE_APPS" <<'EOF'
{"env":{"PATH":"$(PATH):$(HOME)/.local/bin"},"apps":[{"name":"Desktop","image-path":"desktop.png"},{"name":"Steam Big Picture","detached":["setsid steam steam://open/bigpicture"]}]}
EOF
}

@test "adds the Ragnarok app with the documented fields, keeping the other apps" {
    run "$IA" --app
    [ "$status" -eq 0 ]
    jq -e '.apps | map(.name) == ["Desktop","Steam Big Picture","Ragnarok"]' "$SUNSHINE_APPS"
    jq -e '.env.PATH' "$SUNSHINE_APPS" >/dev/null
    jq -e '.apps[2] | .["auto-detach"] == true and .["wait-all"] == true and .["exit-timeout"] == 5' "$SUNSHINE_APPS"
    jq -e --arg r "$REPO" '.apps[2].cmd == $r + "/ragnarok-stream/umu/launch.sh" and (.apps[2] | has("detached") | not)' "$SUNSHINE_APPS"
}

@test "prep-cmd order: prep (panel still on), vmon, resolution, antimicrox, with absolute repo paths" {
    "$IA" --app
    S="$REPO/ragnarok-stream/sunshine"
    jq -e --arg s "$S" '.apps[2]["prep-cmd"] == [
      {"do": ($s+"/prep.sh"), "undo": ($s+"/undo.sh")},
      {"do": ($s+"/vmon-start.sh"), "undo": ($s+"/vmon-stop.sh")},
      {"do": ($s+"/ro-resolution.sh set"), "undo": ($s+"/ro-resolution.sh restore")},
      {"do": ($s+"/antimicrox-start.sh"), "undo": ($s+"/antimicrox-stop.sh")}]' "$SUNSHINE_APPS"
}

@test "--repo overrides the checkout path" {
    "$IA" --app --repo /opt/x
    jq -e '.apps[2]["prep-cmd"][1].do == "/opt/x/ragnarok-stream/sunshine/vmon-start.sh"' "$SUNSHINE_APPS"
}

@test "is idempotent: second run keeps one app and does not rewrite" {
    "$IA" --app
    sum=$(md5sum <"$SUNSHINE_APPS")
    run "$IA" --app
    [ "$status" -eq 0 ]
    [ "$(jq '[.apps[]|select(.name=="Ragnarok")]|length' "$SUNSHINE_APPS")" -eq 1 ]
    [ "$(md5sum <"$SUNSHINE_APPS")" = "$sum" ]
    "$IA" --app --repo /opt/y
    jq -e '.apps[2].cmd == "/opt/y/ragnarok-stream/umu/launch.sh"' "$SUNSHINE_APPS"
}

@test "creates apps.json when absent; --dry-run writes nothing" {
    rm "$SUNSHINE_APPS"
    run "$IA" --app --dry-run
    [ "$status" -eq 0 ]
    [ ! -e "$SUNSHINE_APPS" ]
    "$IA" --app
    jq -e '.apps | length == 1' "$SUNSHINE_APPS"
}

@test "--undo removes only the Ragnarok app" {
    "$IA" --app
    run "$IA" --undo
    [ "$status" -eq 0 ]
    jq -e '.apps | map(.name) == ["Desktop","Steam Big Picture"]' "$SUNSHINE_APPS"
    run "$IA" --undo
    [ "$status" -eq 0 ]
}

@test "--set-conf edits existing keys, appends missing ones, keeps the rest" {
    printf '# comment\ncapture = x11\noutput_name = Virtual-sunshine-vmon\nback_button_timeout=2000' >"$SUNSHINE_CONF"
    run "$IA" --set-conf
    [ "$status" -eq 0 ]
    grep -qx '# comment' "$SUNSHINE_CONF"
    grep -qx 'output_name = Virtual-sunshine-vmon' "$SUNSHINE_CONF"
    grep -qx 'capture = kwin' "$SUNSHINE_CONF"
    grep -qx 'gamepad = x360' "$SUNSHINE_CONF"
    grep -qx 'back_button_timeout = -1' "$SUNSHINE_CONF"
    grep -qx 'system_tray = disabled' "$SUNSHINE_CONF"
    [ "$(grep -c '^capture' "$SUNSHINE_CONF")" -eq 1 ]
    [ ! -e "$SUNSHINE_APPS.antes-ragnarok" ]
}

@test "--set-conf is idempotent and --undo restores the original conf" {
    printf 'capture = x11\nfoo = bar\n' >"$SUNSHINE_CONF"
    cp "$SUNSHINE_CONF" "$BATS_TEST_TMPDIR/orig"
    "$IA" --set-conf
    cp "$SUNSHINE_CONF" "$BATS_TEST_TMPDIR/after"
    "$IA" --set-conf
    cmp "$SUNSHINE_CONF" "$BATS_TEST_TMPDIR/after"
    cmp "$SUNSHINE_CONF.antes-ragnarok" "$BATS_TEST_TMPDIR/orig"
    run "$IA" --undo --set-conf
    [ "$status" -eq 0 ]
    cmp "$SUNSHINE_CONF" "$BATS_TEST_TMPDIR/orig"
    [ ! -e "$SUNSHINE_CONF.ragnarok-keys" ]
    [ -e "$SUNSHINE_CONF.antes-ragnarok" ] # kept only as a manual-recovery backup
}

@test "--set-conf creates a missing conf; undo leaves it empty" {
    run "$IA" --set-conf
    [ "$status" -eq 0 ]
    grep -qx 'capture = kwin' "$SUNSHINE_CONF"
    "$IA" --undo --set-conf
    [ ! -s "$SUNSHINE_CONF" ]
}

@test "--set-conf --dry-run writes nothing" {
    run "$IA" --set-conf --dry-run
    [ "$status" -eq 0 ]
    [ ! -e "$SUNSHINE_CONF" ]
}

@test "bare undo does both; no args and an unknown flag are usage errors" {
    "$IA" --app --set-conf
    "$IA" --undo
    jq -e '.apps | length == 2' "$SUNSHINE_APPS"
    [ ! -s "$SUNSHINE_CONF" ]
    run "$IA"
    [ "$status" -eq 2 ]
    run "$IA" --gameid 5
    [ "$status" -eq 2 ]
}

@test "conf undo restores only our keys and keeps lines the user changed meanwhile" {
    printf 'capture = x11\nfoo = bar\n' >"$SUNSHINE_CONF"
    "$IA" --set-conf
    printf 'bitrate = 20000\n' >>"$SUNSHINE_CONF"
    sed -i 's/^foo = bar/foo = changed/' "$SUNSHINE_CONF"
    run "$IA" --undo --set-conf
    [ "$status" -eq 0 ]
    grep -qx 'capture = x11' "$SUNSHINE_CONF"
    grep -qx 'foo = changed' "$SUNSHINE_CONF"
    grep -qx 'bitrate = 20000' "$SUNSHINE_CONF"
    ! grep -q 'gamepad\|system_tray\|back_button' "$SUNSHINE_CONF"
    [ ! -e "$SUNSHINE_CONF.ragnarok-keys" ]
}

@test "conf install records the previous state once; a second install does not overwrite it" {
    printf 'capture = x11\n' >"$SUNSHINE_CONF"
    "$IA" --set-conf
    cp "$SUNSHINE_CONF.ragnarok-keys" "$BATS_TEST_TMPDIR/keys1"
    "$IA" --set-conf
    cmp "$SUNSHINE_CONF.ragnarok-keys" "$BATS_TEST_TMPDIR/keys1"
    grep -q 'capture' "$SUNSHINE_CONF.ragnarok-keys"
}

@test "app undo removes the stale apps.json.antes-ragnarok" {
    "$IA" --app
    [ -e "$SUNSHINE_APPS.antes-ragnarok" ]
    "$IA" --undo --app
    [ ! -e "$SUNSHINE_APPS.antes-ragnarok" ]
}

@test "re-install merges: user-added fields survive, ours win" {
    "$IA" --app
    jq '.apps |= map(if .name=="Ragnarok" then . + {"image-path":"/x.png","exit-timeout":99} else . end)' "$SUNSHINE_APPS" >"$BATS_TEST_TMPDIR/t"
    cp "$BATS_TEST_TMPDIR/t" "$SUNSHINE_APPS"
    "$IA" --app
    jq -e '.apps[2]["image-path"] == "/x.png" and .apps[2]["exit-timeout"] == 5' "$SUNSHINE_APPS"
}

@test "invalid apps.json aborts before writing anything (conf untouched too)" {
    printf '{not json' >"$SUNSHINE_APPS"
    printf 'capture = x11\n' >"$SUNSHINE_CONF"
    cp "$SUNSHINE_APPS" "$BATS_TEST_TMPDIR/a0"
    cp "$SUNSHINE_CONF" "$BATS_TEST_TMPDIR/c0"
    run "$IA" --app --set-conf
    [ "$status" -ne 0 ]
    cmp "$SUNSHINE_APPS" "$BATS_TEST_TMPDIR/a0"
    cmp "$SUNSHINE_CONF" "$BATS_TEST_TMPDIR/c0"
    [ ! -e "$SUNSHINE_CONF.antes-ragnarok" ]
}

@test "an unusable sunshine.conf (a directory) aborts before touching apps.json" {
    mkdir "$SUNSHINE_CONF"
    cp "$SUNSHINE_APPS" "$BATS_TEST_TMPDIR/a0"
    run "$IA" --app --set-conf
    [ "$status" -ne 0 ]
    cmp "$SUNSHINE_APPS" "$BATS_TEST_TMPDIR/a0"
}

@test "nothing Steam-specific in the generated app" {
    "$IA" --app
    ! jq -c '.apps[] | select(.name=="Ragnarok")' "$SUNSHINE_APPS" | grep -qi steam
}

@test "the game is the app's blocking cmd (not detached), so closing it ends the session and runs undo" {
    "$IA" --app
    jq -e '.apps[2] | .cmd | endswith("/ragnarok-stream/umu/launch.sh")' "$SUNSHINE_APPS"
    jq -e '.apps[2] | has("detached") | not' "$SUNSHINE_APPS"
}

@test "re-install drops a stale detached list from an older install" {
    "$IA" --app
    jq '.apps |= map(if .name=="Ragnarok" then . + {"detached":["setsid x"]} else . end)' "$SUNSHINE_APPS" >"$BATS_TEST_TMPDIR/t"
    cp "$BATS_TEST_TMPDIR/t" "$SUNSHINE_APPS"
    "$IA" --app
    jq -e '.apps[2] | has("detached") | not' "$SUNSHINE_APPS"
}
