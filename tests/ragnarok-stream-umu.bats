#!/usr/bin/env bats
# ragnarok-stream/umu/{launch,bootstrap,setup-prefix}.sh with a fake lscpu and a stub umu-run.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    U="$REPO/ragnarok-stream/umu"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    export LSCPU="$BIN/lscpu"
    cat >"$LSCPU" <<'EOF'
#!/usr/bin/env bash
cat <<OUT
CPU MAXMHZ
0 4600.0000
1 4600.0000
2 4600.0000
3 4600.0000
4 3400.0000
5 3400.0000
6 3400.0000
7 3400.0000
OUT
EOF
    chmod +x "$LSCPU"
    export RO_DIR="$BATS_TEST_TMPDIR/RO"
    mkdir -p "$RO_DIR/fonts"
    touch "$RO_DIR/Ragexe_cerberus.exe"
    echo font >"$RO_DIR/fonts/NanumGothic-Regular.ttf"
    export RO_PREFIX="$BATS_TEST_TMPDIR/pfx"
    export CALLS="$BATS_TEST_TMPDIR/calls"
    : >"$CALLS"
    export UMU_RUN="$BIN/umu-run"
    cat >"$UMU_RUN" <<'EOF'
#!/usr/bin/env bash
echo "umu WINEPREFIX=$WINEPREFIX GAMEID=$GAMEID PROTONPATH=$PROTONPATH STORE=$STORE PWD=$PWD $*" >>"$CALLS"
case "$1 $2" in
"wineboot -u") mkdir -p "$WINEPREFIX/drive_c/windows" && echo REGEDIT >"$WINEPREFIX/system.reg" ;;
"regedit /S") cp "$3" "$CALLS.reg" ;;
"reg query") [ -e "$CALLS.reg" ] && echo "    Gulim    REG_SZ    NanumGothic" ;;
esac
exit 0
EOF
    chmod +x "$UMU_RUN"
}

# ---- launch ---------------------------------------------------------------

@test "launch --dry-run: umu env, tuning ported from the original script, cwd and exe" {
    run "$U/launch.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"WINEPREFIX=$RO_PREFIX"* ]]
    [[ "$output" == *"GAMEID="* ]]
    [[ "$output" == *"PROTONPATH=GE-Proton"* ]]
    [[ "$output" == *"STORE=none"* ]]
    [[ "$output" == *'WINEDLLOVERRIDES=ddraw=n,b'* ]]
    [[ "$output" == *'WINE_CPU_TOPOLOGY=4:0,1,2,3'* ]]
    [[ "$output" == *'LC_ALL=pt_BR.UTF-8'* ]]
    [[ "$output" == *'LANG=pt_BR.UTF-8'* ]]
    [[ "$output" == *'WINEDEBUG=-all'* ]]
    [[ "$output" == *'PULSE_LATENCY_MSEC=60'* ]]
    [[ "$output" == *"cwd: $RO_DIR"* ]]
    [[ "$output" == *"command: taskset -c 0,1,2,3 $UMU_RUN $RO_DIR/Ragexe_cerberus.exe"* ]]
    [ ! -s "$CALLS" ]
}

@test "launch: PROTONPATH and prefix are overridable; the default prefix is under XDG_DATA_HOME" {
    PROTONPATH=/opt/proton run "$U/launch.sh" --dry-run
    [[ "$output" == *"PROTONPATH=/opt/proton"* ]]
    unset RO_PREFIX
    XDG_DATA_HOME="$BATS_TEST_TMPDIR/xdg" run "$U/launch.sh" --dry-run
    [[ "$output" == *"WINEPREFIX=$BATS_TEST_TMPDIR/xdg/ragnarok-stream/pfx"* ]]
}

@test "launch --dry-run: DXVK_CONFIG_FILE only when dxvk.conf exists" {
    run "$U/launch.sh" --dry-run
    [[ "$output" != *DXVK_CONFIG_FILE* ]]
    echo "x = 1" >"$RO_DIR/dxvk.conf"
    run "$U/launch.sh" --dry-run
    [[ "$output" == *"DXVK_CONFIG_FILE=$RO_DIR/dxvk.conf"* ]]
}

@test "launch --dry-run: no detectable cores drops pinning and topology" {
    printf '#!/usr/bin/env bash\nexit 1\n' >"$LSCPU"
    run "$U/launch.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" != *taskset* ]]
    [[ "$output" != *WINE_CPU_TOPOLOGY* ]]
    [[ "$output" == *"command: $UMU_RUN $RO_DIR/Ragexe_cerberus.exe"* ]]
}

@test "launch: really runs umu-run from the RO dir with the env, pinned with taskset" {
    run "$U/launch.sh"
    [ "$status" -eq 0 ]
    grep -q "umu WINEPREFIX=$RO_PREFIX GAMEID=.* PROTONPATH=GE-Proton STORE=none PWD=$RO_DIR $RO_DIR/Ragexe_cerberus.exe" "$CALLS"
}

@test "launch: fails clearly without the exe or without umu-run" {
    rm "$RO_DIR/Ragexe_cerberus.exe"
    run "$U/launch.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Ragexe_cerberus.exe"* ]]
    touch "$RO_DIR/Ragexe_cerberus.exe"
    UMU_RUN=/nonexistent run "$U/launch.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"umu-run"* ]]
}

@test "launch: unknown args are a usage error" {
    run "$U/launch.sh" --bogus
    [ "$status" -eq 2 ]
}

# ---- bootstrap ------------------------------------------------------------

@test "bootstrap: runs wineboot -u with the umu env and reports success" {
    run "$U/bootstrap.sh"
    [ "$status" -eq 0 ]
    grep -q "umu WINEPREFIX=$RO_PREFIX .* wineboot -u" "$CALLS"
    [ -s "$RO_PREFIX/system.reg" ]
}

@test "bootstrap: --dry-run does nothing; an already bootstrapped prefix is skipped" {
    run "$U/bootstrap.sh" --dry-run
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
    "$U/bootstrap.sh"
    : >"$CALLS"
    run "$U/bootstrap.sh"
    [[ "$output" == *"already"* ]]
    [ ! -s "$CALLS" ]
}

# ---- setup-prefix ---------------------------------------------------------

@test "setup-prefix: not bootstrapped yet -> clear message and exit 3" {
    run "$U/setup-prefix.sh"
    [ "$status" -eq 3 ]
    [[ "$output" == *"bootstrap.sh"* ]]
    [ ! -s "$CALLS" ]
}

bootstrapped() { mkdir -p "$RO_PREFIX/drive_c/windows" && echo REGEDIT >"$RO_PREFIX/system.reg"; }

@test "setup-prefix: installs the font and imports the registry through umu-run, once" {
    bootstrapped
    run "$U/setup-prefix.sh"
    [ "$status" -eq 0 ]
    [ -f "$RO_PREFIX/drive_c/windows/Fonts/NanumGothic-Regular.ttf" ]
    grep -q "umu WINEPREFIX=$RO_PREFIX .* regedit /S" "$CALLS"
    [ -e "$RO_PREFIX/.ragnarok-fonts-v1" ]
    : >"$CALLS"
    run "$U/setup-prefix.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already"* ]]
    ! grep -q regedit "$CALLS"
}

@test "setup-prefix: the .reg has font link, replacements and DirectSound" {
    bootstrapped
    "$U/setup-prefix.sh"
    reg=$(iconv -f UTF-16 -t UTF-8 "$CALLS.reg")
    [[ "$reg" == *'FontLink\SystemLink'* ]]
    [[ "$reg" == *'"Tahoma"=hex(7):'* ]]
    [[ "$reg" == *'"Gulim"="NanumGothic"'* ]]
    [[ "$reg" == *'"HardwareAcceleration"="Emulation"'* ]]
}

@test "setup-prefix: --dry-run changes nothing; a missing font fails" {
    bootstrapped
    run "$U/setup-prefix.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would"* ]]
    [ ! -e "$RO_PREFIX/drive_c/windows/Fonts" ]
    [ ! -s "$CALLS" ]
    rm "$RO_DIR/fonts/NanumGothic-Regular.ttf"
    run "$U/setup-prefix.sh"
    [ "$status" -eq 1 ]
}

# ---- auto-login (typed with ydotool by autotype-login.sh) ------------------

mk_login() { # mk_login <mode> <content>
    export RO_LOGIN_FILE="$BATS_TEST_TMPDIR/login"
    printf '%b' "$2" >"$RO_LOGIN_FILE"
    chmod "$1" "$RO_LOGIN_FILE"
}

# stub helper: records that it was started, and with which argv/env password (it must get none)
mk_autotype() {
    export AUTOTYPE="$BATS_TEST_TMPDIR/autotype"
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    printf '#!/usr/bin/%s\necho "autotype started args=[$*] pw=[${SECRET:-}]" >>"$CALLS.autotype"\n' env' bash' >"$AUTOTYPE"
    chmod +x "$AUTOTYPE"
    export YDOTOOL_SOCKET="$BATS_TEST_TMPDIR/ydotool.sock"
    touch "$YDOTOOL_SOCKET"
}

@test "login: the game argv has no SSO/-t: arguments any more, even with a valid login file" {
    mk_login 600 'brno\nsup3rsecret\n'
    mk_autotype
    run "$U/launch.sh"
    [ "$status" -eq 0 ]
    grep -q "Ragexe_cerberus.exe$" "$CALLS"
    ! grep -q -- '-t:\|1rag1\|sup3rsecret' "$CALLS"
    [[ "$output" != *sup3rsecret* ]]
}

@test "login: a valid file and the ydotool socket start the helper detached, with no password in argv/env" {
    mk_login 600 'brno\nsup3rsecret\n'
    mk_autotype
    run "$U/launch.sh"
    [ "$status" -eq 0 ]
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CALLS.autotype" ] && break; sleep 0.1; done
    grep -q 'autotype started args=\[\] pw=\[\]' "$CALLS.autotype"
    [[ "$output" != *sup3rsecret* ]]
}

@test "login: 400 is accepted too" {
    mk_login 400 'brno\nsup3rsecret\n'
    mk_autotype
    run "$U/launch.sh"
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CALLS.autotype" ] && break; sleep 0.1; done
    [ -s "$CALLS.autotype" ]
}

@test "login: mode 644 -> helper not started, a clear log line, the password never printed" {
    mk_login 644 'brno\nsup3rsecret\n'
    mk_autotype
    run "$U/launch.sh"
    [ "$status" -eq 0 ]
    sleep 0.3
    [ ! -e "$CALLS.autotype" ]
    [[ "$output" == *"login"*"600"* ]]
    [[ "$output" != *sup3rsecret* ]]
}

@test "login: no ydotool socket -> helper not started, with a log line" {
    mk_login 600 'brno\nsup3rsecret\n'
    mk_autotype
    rm -f "$YDOTOOL_SOCKET"
    run "$U/launch.sh"
    [ "$status" -eq 0 ]
    sleep 0.3
    [ ! -e "$CALLS.autotype" ]
    [[ "$output" == *ydotool* ]]
}

@test "login: missing file -> plain launch, silent, no helper" {
    export RO_LOGIN_FILE="$BATS_TEST_TMPDIR/nope"
    mk_autotype
    run "$U/launch.sh"
    [ "$status" -eq 0 ]
    sleep 0.3
    [ ! -e "$CALLS.autotype" ]
    [[ "$output" != *login* ]]
}

@test "login: an empty line or a symlink is refused" {
    mk_autotype
    mk_login 600 'brno\n\n'
    run "$U/launch.sh"
    [[ "$output" == *login* ]]
    mk_login 600 'brno\nsup3rsecret\n'
    ln -sf "$RO_LOGIN_FILE" "$BATS_TEST_TMPDIR/link"
    RO_LOGIN_FILE="$BATS_TEST_TMPDIR/link" run "$U/launch.sh"
    [[ "$output" != *sup3rsecret* ]]
    sleep 0.3
    [ ! -e "$CALLS.autotype" ]
}

@test "login: --dry-run says auto-login is on and never shows the password" {
    mk_login 600 'brno\nsup3rsecret\n'
    mk_autotype
    run "$U/launch.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto-login"* ]]
    [[ "$output" != *sup3rsecret* ]]
    [[ "$output" != *-t:* ]]
    [ ! -s "$CALLS" ]
    [ ! -e "$CALLS.autotype" ]
}
