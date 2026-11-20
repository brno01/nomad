# shellcheck shell=bash disable=SC2034 # LOGIN_* are read by the sourcing scripts
# Optional auto-login credentials for the RO client (sourced by launch.sh and the installer's --check).
# File (default ${XDG_CONFIG_HOME:-~/.config}/ragnarok-stream/login, override RO_LOGIN_FILE): line 1 = username,
# line 2 = password. The user creates it by hand; nothing here ever writes it or prints the password.
#
# login_validate FILE
#   returns 0 and sets LOGIN_USER / LOGIN_PASS     valid
#   returns 1                                      FILE does not exist (nothing to do)
#   returns 2 and sets LOGIN_ERR (no secrets)      exists but must not be used
# A valid file is a regular file (symlinks refused), owned by the current user, mode 600 or 400, with a
# non-empty username on line 1 and a non-empty password on line 2.

RO_LOGIN_FILE=${RO_LOGIN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/ragnarok-stream/login}

login_validate() {
    local f=$1 mode owner
    LOGIN_USER="" LOGIN_PASS="" LOGIN_ERR=""
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 1; fi
    if [ -L "$f" ] || [ ! -f "$f" ]; then
        LOGIN_ERR="login file $f is not a regular file (symlinks are refused); not using it"
        return 2
    fi
    owner=$(stat -c %u "$f" 2>/dev/null || echo "?")
    if [ "$owner" != "$(id -u)" ]; then
        LOGIN_ERR="login file $f is not owned by you; not using it"
        return 2
    fi
    mode=$(stat -c %a "$f" 2>/dev/null || echo "?")
    if [ "$mode" != 600 ] && [ "$mode" != 400 ]; then
        LOGIN_ERR="login file $f has mode $mode, it must be 600 or 400 (fix: chmod 600 $f); not using it"
        return 2
    fi
    LOGIN_USER=$(sed -n '1p' "$f" | tr -d '\r')
    LOGIN_PASS=$(sed -n '2p' "$f" | tr -d '\r')
    if [ -z "$LOGIN_USER" ] || [ -z "$LOGIN_PASS" ]; then
        LOGIN_USER="" LOGIN_PASS=""
        LOGIN_ERR="login file $f needs the username on line 1 and the password on line 2; not using it"
        return 2
    fi
    return 0
}
