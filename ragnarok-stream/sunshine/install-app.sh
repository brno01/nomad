#!/usr/bin/env bash
# Merge the "Ragnarok" app into Sunshine's apps.json and/or set the sunshine.conf keys it needs.
#
# Usage: install-app.sh [--app] [--set-conf] [--repo DIR] [--dry-run] [--undo]
#   --app        (re)write the app: cmd = umu/launch.sh, run in the FOREGROUND (no detached list)
#   --set-conf   ensure in sunshine.conf: capture = kwin, gamepad = x360,
#                back_button_timeout = -1, system_tray = disabled
#   --undo       remove the app and/or put back ONLY our four conf keys (state in <conf>.ragnarok-keys;
#                <conf>.antes-ragnarok stays as a manual-recovery backup); neither flag = undo both
#   --repo DIR   checkout root (default: derived from this script's location)
# Env: SUNSHINE_APPS (default ~/.config/sunshine/apps.json), SUNSHINE_CONF (…/sunshine.conf).
#
# Schema (verified against current Sunshine):
#  - apps.json: {"env": {...}, "apps": [ {name, cmd, detached[], prep-cmd[{do,undo,elevated}],
#    auto-detach, wait-all, exit-timeout, image-path, working-dir, output, ...} ]}.
#    Keys, types and defaults (auto-detach true, wait-all true, exit-timeout 5; empty cmd = desktop-like
#    app) read from src/process.cpp proc::parse():
#    https://github.com/LizardByte/Sunshine/blob/master/src/process.cpp
#    App docs / examples (prep-cmd, detached):
#    https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2app__examples.html
#  - sunshine.conf keys capture / gamepad / back_button_timeout / system_tray:
#    https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html
#    The docs list system_tray only as "enabled"; src/config.cpp parses it as a boolean where anything
#    but true/yes/enable(d)/on/1 is false, so "disabled" works.
# Sunshine runs prep-cmd "do" entries in order and "undo" entries in reverse order.
set -euo pipefail

APPS=${SUNSHINE_APPS:-$HOME/.config/sunshine/apps.json}
CONF=${SUNSHINE_CONF:-$HOME/.config/sunshine/sunshine.conf}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
APP_NAME=Ragnarok
SUFFIX=.antes-ragnarok
APP=0 SET_CONF=0 UNDO=0 DRY=0

log() { printf '%s\n' "$*"; }
usage() {
    printf 'usage: %s [--app] [--set-conf] [--repo DIR] [--dry-run] [--undo]\n' "$0" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case $1 in
    --app) APP=1; shift ;;
    --set-conf) SET_CONF=1; shift ;;
    --repo) REPO=${2:?--repo needs a value}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --undo) UNDO=1; shift ;;
    *) usage ;;
    esac
done


do_app=0 do_conf=0
[ "$APP" = 1 ] && do_app=1
[ "$SET_CONF" = 1 ] && do_conf=1
if [ "$do_app" = 0 ] && [ "$do_conf" = 0 ]; then
    [ "$UNDO" = 1 ] || usage
    do_app=1 do_conf=1
fi
command -v jq >/dev/null || { echo "error: jq not found (brew install jq)" >&2; exit 1; }

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Validate everything BEFORE writing anything, so a bad file aborts with both files untouched.
if [ "$do_app" = 1 ] && [ -e "$APPS" ]; then
    if [ ! -f "$APPS" ] || [ ! -r "$APPS" ]; then die "$APPS is not a readable regular file"; fi
    if [ -s "$APPS" ]; then
        jq -e 'type == "object" and ((.apps // []) | type == "array")' "$APPS" >/dev/null 2>&1 ||
            die "$APPS is not a valid apps.json (object with an apps array); fix it or move it away"
    fi
fi
if [ "$do_conf" = 1 ] && [ -e "$CONF" ]; then
    if [ ! -f "$CONF" ] || [ ! -r "$CONF" ]; then die "$CONF is not a readable regular file"; fi
fi

backup_once() { # backup_once FILE: copy to FILE.antes-ragnarok before the first edit (manual recovery only)
    [ -e "$1$SUFFIX" ] && return 0
    if [ -e "$1" ]; then cp -p "$1" "$1$SUFFIX"; else : >"$1$SUFFIX"; fi
    log "backup  $1$SUFFIX"
}

# ---- apps.json ---------------------------------------------------------

app_json() {
    local s=$REPO/ragnarok-stream/sunshine
    # Order matters: Sunshine runs "do" in order and "undo" in REVERSE. prep.sh first so it reads the
    # internal panel's brightness while the panel is still enabled; on undo the panels come back
    # (vmon-stop) before the brightness is restored; AntiMicroX last (needs nothing from the others).
    jq -n --arg name "$APP_NAME" --arg r "$REPO" --arg s "$s" '{
        name: $name,
        cmd: "\($r)/ragnarok-stream/umu/launch.sh",
        "auto-detach": true,
        "wait-all": true,
        "exit-timeout": 5,
        "prep-cmd": [
            {do: "\($s)/prep.sh",              undo: "\($s)/undo.sh"},
            {do: "\($s)/vmon-start.sh",        undo: "\($s)/vmon-stop.sh"},
            {do: "\($s)/ro-resolution.sh set", undo: "\($s)/ro-resolution.sh restore"},
            {do: "\($s)/antimicrox-start.sh",  undo: "\($s)/antimicrox-stop.sh"}
        ]
    }'
}

write_apps() { # write_apps NEWJSON
    local new=$1
    if [ -e "$APPS" ] && [ "$(jq -cS . "$APPS")" = "$(jq -cS . <<<"$new")" ]; then
        log "ok      $APPS"
        return 0
    fi
    if [ "$DRY" = 1 ]; then
        log "would write $APPS"
        return 0
    fi
    mkdir -p "$(dirname "$APPS")"
    backup_once "$APPS"
    jq . <<<"$new" >"$APPS.tmp" && mv "$APPS.tmp" "$APPS"
    log "wrote   $APPS"
}

apps_current() { if [ -s "$APPS" ]; then cat "$APPS"; else echo '{"apps":[]}'; fi; }

if [ "$do_app" = 1 ]; then
    if [ "$UNDO" = 1 ]; then
        if [ ! -e "$APPS" ]; then
            log "ok      $APPS absent"
        else
            new=$(apps_current | jq --arg n "$APP_NAME" '.apps = ((.apps // []) | map(select(.name != $n)))')
            write_apps "$new"
        fi
        # the backup was taken before our first edit; once the app is gone it is stale
        if [ "$DRY" = 1 ]; then
            [ -e "$APPS$SUFFIX" ] && log "would remove stale $APPS$SUFFIX"
        elif [ -e "$APPS$SUFFIX" ]; then
            rm -f "$APPS$SUFFIX"
            log "removed stale $APPS$SUFFIX"
        fi
    else
        app=$(app_json)
        # merge (. + $a) on an existing entry: user-added fields such as image-path survive, ours win
        new=$(apps_current | jq --argjson a "$app" --arg n "$APP_NAME" '
            .apps = ((.apps // []) | if any(.[]; .name == $n)
                     then map(if .name == $n then (. + $a | del(.detached)) else . end)
                     else . + [$a] end)')
        write_apps "$new"
    fi
fi

# ---- sunshine.conf -----------------------------------------------------

CONF_KEYS=("capture=kwin" "gamepad=x360" "back_button_timeout=-1" "system_tray=disabled")
KEYS_STATE=$CONF.ragnarok-keys # previous state of each key we set: "A<TAB>key" (absent) or "P<TAB>key<TAB>line"

conf_lines() { # fills the global array `lines` from $CONF
    local line
    lines=()
    if [ -e "$CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done <"$CONF"
    fi
}

conf_print() { if [ "${#lines[@]}" -gt 0 ]; then printf '%s\n' "${lines[@]}"; fi; }

conf_render() { # print CONF with the wanted keys set (edit in place, else append)
    local kv k v i seen
    conf_lines
    for kv in "${CONF_KEYS[@]}"; do
        k=${kv%%=*} v=${kv#*=} seen=0
        for i in "${!lines[@]}"; do
            if [[ "${lines[$i]}" =~ ^[[:space:]]*${k}[[:space:]]*= ]]; then
                lines[i]="$k = $v" seen=1
            fi
        done
        [ "$seen" = 1 ] || lines+=("$k = $v")
    done
    conf_print
}

conf_record_keys() { # once: remember what each key looked like before we touched it
    local kv k i first
    [ -e "$KEYS_STATE" ] && return 0
    conf_lines
    : >"$KEYS_STATE.tmp"
    for kv in "${CONF_KEYS[@]}"; do
        k=${kv%%=*} first=""
        for i in "${!lines[@]}"; do
            if [[ "${lines[$i]}" =~ ^[[:space:]]*${k}[[:space:]]*= ]]; then first=${lines[$i]}; break; fi
        done
        if [ -n "$first" ]; then printf 'P\t%s\t%s\n' "$k" "$first"; else printf 'A\t%s\n' "$k"; fi >>"$KEYS_STATE.tmp"
    done
    mv "$KEYS_STATE.tmp" "$KEYS_STATE"
}

conf_undo_render() { # print CONF with ONLY our keys put back; every other line stays as it is now
    local kind k orig i first
    conf_lines
    while IFS=$'\t' read -r kind k orig; do
        first=1
        for i in "${!lines[@]}"; do
            if [[ "${lines[$i]}" =~ ^[[:space:]]*${k}[[:space:]]*= ]]; then
                if [ "$kind" = P ] && [ "$first" = 1 ]; then lines[i]=$orig; else unset 'lines[i]'; fi
                first=0
            fi
        done
        if [ "$kind" = P ] && [ "$first" = 1 ]; then lines+=("$orig"); fi
    done <"$KEYS_STATE"
    conf_print
}

if [ "$do_conf" = 1 ]; then
    if [ "$UNDO" = 1 ]; then
        if [ ! -e "$KEYS_STATE" ]; then
            log "ok      no $KEYS_STATE: nothing to restore in $CONF"
        elif [ "$DRY" = 1 ]; then
            log "would restore our keys in $CONF"
        else
            tmp=$(mktemp)
            conf_undo_render >"$tmp"
            cat "$tmp" >"$CONF"
            rm -f "$tmp" "$KEYS_STATE"
            log "restored our keys in $CONF ($CONF$SUFFIX is kept as a manual-recovery backup)"
        fi
    else
        tmp=$(mktemp)
        conf_render >"$tmp"
        if [ -e "$CONF" ] && cmp -s "$tmp" "$CONF"; then
            log "ok      $CONF"
        elif [ "$DRY" = 1 ]; then
            log "would update $CONF"
        else
            mkdir -p "$(dirname "$CONF")"
            backup_once "$CONF"
            conf_record_keys
            cat "$tmp" >"$CONF"
            log "wrote   $CONF"
        fi
        rm -f "$tmp"
    fi
fi
exit 0
