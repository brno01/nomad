# shellcheck shell=bash
# Shared by launch.sh / bootstrap.sh / setup-prefix.sh (sourced, not executed): the ONE place that
# defines the umu environment and the tuning ported from the user's iniciar-cerberus.sh (Wine).
#
# umu-launcher variables (https://github.com/Open-Wine-Components/umu-launcher, README and docs/umu.1.scd):
#   WINEPREFIX  where the prefix lives (we use a dedicated one)
#   GAMEID      "an arbitrary value or a valid id in the umu-database"; unset = umu-default (no protonfixes).
#               An arbitrary id applies no fixes.
#   PROTONPATH  "path to a Proton directory, version name (e.g. GE-Proton9-5) or codename (e.g. GE-Proton)";
#               "GE-Proton" makes umu download the latest GE-Proton; unset = UMU-Proton.
#   STORE       storefront id, arbitrary or from the umu-database; default "none".
#
# Env: RO_DIR (default ~/Desktop/RO), RO_EXE, RO_PREFIX, PROTONPATH, GAMEID, STORE, UMU_RUN, RO_LOCALE, LSCPU.

RO_DIR=${RO_DIR:-$HOME/Desktop/RO}
RO_EXE=${RO_EXE:-Ragexe_cerberus.exe}
RO_PREFIX=${RO_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/ragnarok-stream/pfx}
PROTONPATH=${PROTONPATH:-GE-Proton}
GAMEID=${GAMEID:-ragnarok-stream}
STORE=${STORE:-none}
UMU_RUN=${UMU_RUN:-umu-run}
RO_LOCALE=${RO_LOCALE:-pt_BR.UTF-8}
LSCPU=${LSCPU:-lscpu}

log() { printf '%s\n' "$*"; }
die() {
    printf 'error: %s\n' "$1" >&2
    exit "${2:-1}"
}

# Environment of every umu-run call (as KEY=VALUE words for `env`).
umu_env() { printf '%s\n' "WINEPREFIX=$RO_PREFIX" "GAMEID=$GAMEID" "PROTONPATH=$PROTONPATH" "STORE=$STORE"; }

# umu <args...>: run umu-run with the umu environment.
umu() {
    local -a e
    mapfile -t e < <(umu_env)
    env "${e[@]}" "$UMU_RUN" "$@"
}

# P-cores = the CPUs with the highest max frequency (hybrid Intel: i5-1334U -> 0-3, E-cores 4-11);
# same detection as the original script. Prints "0,1,2,3" or nothing.
detect_pcores() {
    LC_ALL=C "$LSCPU" -e=CPU,MAXMHZ 2>/dev/null |
        awk 'NR>1{m[$1]=$2+0; if($2+0>x)x=$2+0} END{for(c in m) if(m[c]==x) print c}' | sort -n | paste -sd, - || true
}

# Prefix exists and Proton has initialised it (wineboot wrote the registry).
prefix_bootstrapped() { [ -s "$RO_PREFIX/system.reg" ] && [ -d "$RO_PREFIX/drive_c/windows" ]; }
