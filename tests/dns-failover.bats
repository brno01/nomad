#!/usr/bin/env bats
# scripts/dns-failover.sh against fake tailscale/dig; scripts/dns-failover-install.sh
# against temp dirs.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    FAKE="$BATS_TEST_TMPDIR/fake"
    mkdir -p "$FAKE"
    export STATE_DIR="$BATS_TEST_TMPDIR/state" PIHOLE_IP=100.64.0.53
    export TAILSCALE="$FAKE/tailscale" DIG="$FAKE/dig" FAKE

    # fake tailscale: state in $FAKE/backend and $FAKE/corpdns, records "set" calls
    cat > "$TAILSCALE" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    status) printf '{"BackendState":"%s"}' "$(cat "$FAKE/backend")" ;;
    debug) printf '{"CorpDNS":%s}' "$(cat "$FAKE/corpdns")" ;;
    set) echo "$2" >> "$FAKE/sets"
         case "$2" in
             --accept-dns=false) echo false > "$FAKE/corpdns" ;;
             --accept-dns=true) echo true > "$FAKE/corpdns" ;;
         esac ;;
esac
EOF
    # fake dig: answers NOERROR unless $FAKE/down exists
    cat > "$DIG" <<'EOF'
#!/usr/bin/env bash
[ -e "$FAKE/down" ] && exit 9
echo ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1'
EOF
    chmod +x "$TAILSCALE" "$DIG"
    echo Running > "$FAKE/backend"
    echo true > "$FAKE/corpdns"
}

sets() { cat "$FAKE/sets" 2>/dev/null || true; }

@test "pihole up: does nothing" {
    run "$REPO/scripts/dns-failover.sh"
    [ "$status" -eq 0 ]
    [ -z "$(sets)" ]
}

@test "one failure is not enough to switch" {
    touch "$FAKE/down"
    run "$REPO/scripts/dns-failover.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(1/2)"* ]]
    [ -z "$(sets)" ]
}

@test "two failures turn tailscale DNS off" {
    touch "$FAKE/down"
    "$REPO/scripts/dns-failover.sh"
    run "$REPO/scripts/dns-failover.sh"
    [ "$status" -eq 0 ]
    [ "$(sets)" = "--accept-dns=false" ]
    [ -e "$STATE_DIR/disabled-by-failover" ]
}

@test "pihole back: turns tailscale DNS on again" {
    touch "$FAKE/down"
    "$REPO/scripts/dns-failover.sh"; "$REPO/scripts/dns-failover.sh"
    rm "$FAKE/down"
    run "$REPO/scripts/dns-failover.sh"
    [ "$status" -eq 0 ]
    [ "$(sets | tail -1)" = "--accept-dns=true" ]
    [ ! -e "$STATE_DIR/disabled-by-failover" ]
}

@test "keeps a manual --accept-dns=false" {
    echo false > "$FAKE/corpdns"
    touch "$FAKE/down"
    "$REPO/scripts/dns-failover.sh"; "$REPO/scripts/dns-failover.sh"
    rm "$FAKE/down"
    run "$REPO/scripts/dns-failover.sh"
    [ "$status" -eq 0 ]
    [ -z "$(sets)" ]
}

@test "a success resets the failure count" {
    touch "$FAKE/down"
    "$REPO/scripts/dns-failover.sh"
    rm "$FAKE/down"
    "$REPO/scripts/dns-failover.sh"
    touch "$FAKE/down"
    run "$REPO/scripts/dns-failover.sh"
    [[ "$output" == *"(1/2)"* ]]
    [ -z "$(sets)" ]
}

@test "tailscale not running: does nothing" {
    echo Stopped > "$FAKE/backend"
    touch "$FAKE/down"
    "$REPO/scripts/dns-failover.sh"
    run "$REPO/scripts/dns-failover.sh"
    [ "$status" -eq 0 ]
    [ -z "$(sets)" ]
}

install_env() {
    export ETC_DIR="$BATS_TEST_TMPDIR/etc" BIN_DIR="$BATS_TEST_TMPDIR/bin" SKIP_SYSTEMCTL=1
    mkdir -p "$ETC_DIR" "$BIN_DIR"
}

@test "installer writes binary, service and timer; second run changes nothing" {
    install_env
    run "$REPO/scripts/dns-failover-install.sh"
    [ "$status" -eq 0 ]
    [ -x "$BIN_DIR/nomad-dns-failover" ]
    grep -q "Environment=PIHOLE_IP=100.64.0.53" "$ETC_DIR/nomad-dns-failover.service"
    grep -q "ExecStart=$BIN_DIR/nomad-dns-failover" "$ETC_DIR/nomad-dns-failover.service"
    grep -q 'OnUnitActiveSec=30s' "$ETC_DIR/nomad-dns-failover.timer"
    before=$(find "$ETC_DIR" "$BIN_DIR" -type f -exec md5sum {} + | sort)
    run "$REPO/scripts/dns-failover-install.sh"
    [ "$(find "$ETC_DIR" "$BIN_DIR" -type f -exec md5sum {} + | sort)" = "$before" ]
    [[ "$output" != *wrote* ]]
}

@test "installer --dry-run writes nothing; --undo removes everything" {
    install_env
    run "$REPO/scripts/dns-failover-install.sh" --dry-run
    [ "$status" -eq 0 ]
    [ -z "$(find "$ETC_DIR" "$BIN_DIR" -type f)" ]
    "$REPO/scripts/dns-failover-install.sh"
    run "$REPO/scripts/dns-failover-install.sh" --undo
    [ "$status" -eq 0 ]
    [ -z "$(find "$ETC_DIR" "$BIN_DIR" -type f)" ]
}

@test "installer without PIHOLE_IP and without config.local.env refuses to install" {
    install_env
    unset PIHOLE_IP
    LOCAL_ENV="$BATS_TEST_TMPDIR/nao-existe.env" run "$REPO/scripts/dns-failover-install.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"set PIHOLE_IP"* ]]
    [ ! -e "$BIN_DIR/nomad-dns-failover" ]
}

@test "installer reads PIHOLE_IP from config.local.env" {
    install_env
    unset PIHOLE_IP
    printf 'PIHOLE_IP=192.0.2.53\n' > "$BATS_TEST_TMPDIR/local.env"
    LOCAL_ENV="$BATS_TEST_TMPDIR/local.env" run "$REPO/scripts/dns-failover-install.sh"
    [ "$status" -eq 0 ]
    grep -q "Environment=PIHOLE_IP=192.0.2.53" "$ETC_DIR/nomad-dns-failover.service"
}
