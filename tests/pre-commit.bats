#!/usr/bin/env bats
# .githooks/pre-commit in a throwaway repo: a token-shaped string is blocked, a clean file passes.

setup() {
    command -v gitleaks >/dev/null || skip "gitleaks not installed"
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    T="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$T" && cd "$T"
    git init -q . && git config user.email t@example.com && git config user.name t
    git config core.hooksPath "$REPO/.githooks"
}

@test "blocks a commit that stages a GitHub token" {
    printf 'token = "ghp_%s"\n' "R7qLm2Xv9KpTz4WbN8cYd3HsJf6GaE1uOi5V" > leak.txt
    git add leak.txt
    run git commit -q -m "add token"
    [ "$status" -ne 0 ]
    [[ "$output" == *"leaks found"* ]]
    [[ "$output" != *"R7qLm2Xv9KpTz4WbN8cYd3HsJf6GaE1uOi5V"* ]]   # --redact
}

@test "lets a clean commit through" {
    echo "hello" > ok.txt
    git add ok.txt
    run git commit -q -m "clean"
    [ "$status" -eq 0 ]
}

@test "fails closed when gitleaks is missing" {
    echo "hello" > ok.txt
    git add ok.txt
    PATH=/usr/bin:/bin run sh "$REPO/.githooks/pre-commit"
    # only meaningful where gitleaks is not under /usr/bin or /bin
    if PATH=/usr/bin:/bin command -v gitleaks >/dev/null; then skip "gitleaks is in /usr/bin"; fi
    [ "$status" -eq 1 ]
    [[ "$output" == *"gitleaks not found"* ]]
}
