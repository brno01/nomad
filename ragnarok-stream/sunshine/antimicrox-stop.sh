#!/usr/bin/env bash
# Sunshine "undo" command: stop OUR watcher first (so it cannot restart anything), then OUR AntiMicroX. Each pid
# is only killed if its cmdline still looks like ours (a reused pid is left alone). Always exits 0.
# Env: STATE_DIR.
set -euo pipefail
trap 'exit 0' EXIT

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh disable=SC1091
. "$here/lib.sh"
# shellcheck source=antimicrox-lib.sh disable=SC1091
. "$here/antimicrox-lib.sh"

stop_watcher || record_error antimicrox-stop.sh "could not stop the watcher"
stop_amx || record_error antimicrox-stop.sh "could not stop AntiMicroX"
exit 0
