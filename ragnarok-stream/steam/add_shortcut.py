"""Add (or remove) a non-Steam shortcut and its Proton mapping.

Run:
    uv run --no-project --with vdf python -I ragnarok-stream/steam/add_shortcut.py \
        --exe /path/to/ragnarok.exe [--dry-run | --undo]

Edits, with Steam CLOSED (Steam rewrites both files on exit):
  - <steam-root>/userdata/<accountid>/config/shortcuts.vdf   (binary VDF)
  - <steam-root>/config/config.vdf                           (text VDF, CompatToolMapping)

appid scheme (verified against Steam ROM Manager's generate-app-id.ts,
https://github.com/SteamGridDB/steam-rom-manager):
    preliminary = (crc32(exe + name) | 0x80000000)          # exe as stored, with quotes
    shortcuts.vdf "appid"  = preliminary as signed int32     # classic key, lowercase
    unsigned appid         = preliminary (also the compatdata dir and the
                             CompatToolMapping key)
    gameid64               = (unsigned appid << 32) | 0x02000000
                             -> steam://rungameid/<gameid64>
Recent Steam versions read the explicit "appid" field of each entry, so the
value is not recomputed from the name/exe; we still write the classic value so
that it matches what Steam ROM Manager and friends would produce.

config.vdf path (verified against ProtonUp-Qt's steamutil.py, which notes that
Steam uses both 'Valve'/'valve' and 'Steam'/'steam'):
    InstallConfigStore > Software > Valve|valve > Steam|steam > CompatToolMapping
        > "<unsigned appid>" { "name" "<tool>"  "config" ""  "priority" "250" }
Keys are matched case-insensitively and created ("Valve"/"Steam") if missing.
"""
import argparse
import os
import sys
import zlib
from pathlib import Path

try:
    import vdf
except ImportError:  # pragma: no cover
    sys.exit("error: the 'vdf' module is missing; run with: uv run --no-project --with vdf python -I ...")

EXIT_STEAM_RUNNING = 3
BACKUP_SUFFIX = ".antes-ragnarok"


# ---- appid math -----------------------------------------------------------

def compute_appid(exe_as_stored, name):
    """Unsigned 32-bit shortcut appid (classic Steam scheme)."""
    return zlib.crc32((exe_as_stored + name).encode("utf-8")) | 0x80000000


def to_signed32(value):
    return value - 2**32 if value >= 2**31 else value


def compute_gameid(appid):
    """64-bit id used by steam://rungameid/."""
    return (appid << 32) | 0x02000000


# ---- helpers --------------------------------------------------------------

def find_key(d, name):
    """Return the existing key in dict `d` equal to `name` ignoring case, else None."""
    for k in d:
        if isinstance(k, str) and k.lower() == name.lower():
            return k
    return None


def get_or_create(d, name):
    k = find_key(d, name)
    if k is None:
        d[name] = {}
        k = name
    return d[k]


def steam_running():
    if os.environ.get("STEAM_RUNNING_CHECK") == "0":
        return False
    proc = Path(os.environ.get("STEAM_PROC_DIR", "/proc"))
    try:
        entries = list(proc.iterdir())
    except OSError:
        return False
    for p in entries:
        if not p.name.isdigit():
            continue
        try:
            comm = (p / "comm").read_text().strip()
        except OSError:
            continue
        if comm in ("steam", "steamwebhelper"):
            return True
    return False


def backup(path):
    if not path.exists():
        return
    bak = path.with_name(path.name + BACKUP_SUFFIX)
    if not bak.exists():
        bak.write_bytes(path.read_bytes())
        print(f"backup: {bak}")


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp-ragnarok")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def pick_account(root, account_id):
    if account_id:
        return account_id
    ud = root / "userdata"
    dirs = sorted(p.name for p in ud.iterdir() if p.is_dir()) if ud.is_dir() else []
    if len(dirs) == 1:
        return dirs[0]
    print(
        f"error: cannot auto-detect the account; found {len(dirs)} dirs in {ud}: "
        f"{', '.join(dirs) or '(none)'}. Pass --account-id.",
        file=sys.stderr,
    )
    sys.exit(2)


# ---- shortcuts.vdf --------------------------------------------------------

def load_shortcuts(path):
    if not path.exists():
        return {"shortcuts": {}}, "shortcuts"
    data = vdf.binary_loads(path.read_bytes())
    key = find_key(data, "shortcuts")
    if key is None:
        data["shortcuts"] = {}
        key = "shortcuts"
    return data, key


def ordered_entries(data, key):
    items = data[key]
    return [items[k] for k in sorted(items, key=lambda x: int(x) if str(x).isdigit() else 10**9)]


def find_entry(entries, name):
    for i, e in enumerate(entries):
        k = find_key(e, "AppName")
        if k is not None and e[k] == name:
            return i
    return None


def build_entry(args, exe_q, start_q, appid):
    return {
        "appid": to_signed32(appid),
        "AppName": args.name,
        "Exe": exe_q,
        "StartDir": start_q,
        "icon": "",
        "ShortcutPath": "",
        "LaunchOptions": args.launch_options,
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 0,
        "FlatpakAppID": "",
        "tags": {},
    }


# ---- config.vdf -----------------------------------------------------------

def load_config(path):
    if not path.exists():
        return {}
    return vdf.loads(path.read_text(encoding="utf-8"))


def compat_mapping(cfg, create):
    """Return the CompatToolMapping dict (creating the path if `create`), else None."""
    node = cfg
    for name in ("InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"):
        k = find_key(node, name)
        if k is None:
            if not create:
                return None
            node[name] = {}
            k = name
        node = node[k]
    return node


# ---- main -----------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="Add/remove the Ragnarok non-Steam shortcut and Proton mapping.")
    ap.add_argument("--steam-root", default="~/.local/share/Steam")
    ap.add_argument("--account-id")
    ap.add_argument("--name", default="Ragnarok (stream)")
    ap.add_argument("--exe", required=True, help="path to the RO client .exe")
    ap.add_argument("--start-dir")
    ap.add_argument("--launch-options", default="")
    ap.add_argument("--compat-tool", default="proton_experimental")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--undo", action="store_true")
    ap.add_argument("--allow-running", action="store_true", help="testing only: skip the Steam-running check")
    args = ap.parse_args(argv)

    root = Path(args.steam_root).expanduser()
    exe = os.path.abspath(os.path.expanduser(args.exe))
    start_dir = os.path.abspath(os.path.expanduser(args.start_dir)) if args.start_dir else os.path.dirname(exe)
    exe_q, start_q = f'"{exe}"', f'"{start_dir}"'
    appid = compute_appid(exe_q, args.name)

    if steam_running() and not args.allow_running:
        if args.dry_run:
            print("warning: Steam is running; a real run would be refused", file=sys.stderr)
        else:
            print("error: Steam is running; close it completely (File > Exit) and retry. "
                  "Steam overwrites these files on exit.", file=sys.stderr)
            return EXIT_STEAM_RUNNING

    account = pick_account(root, args.account_id)
    sc_path = root / "userdata" / account / "config" / "shortcuts.vdf"
    cfg_path = root / "config" / "config.vdf"
    dry = args.dry_run
    tag = "would " if dry else ""

    # shortcuts.vdf
    sc_exists = sc_path.exists()
    data, key = load_shortcuts(sc_path)
    entries = ordered_entries(data, key)
    idx = find_entry(entries, args.name)
    old_appid = None
    if idx is not None and "appid" in entries[idx]:
        old_appid = entries[idx]["appid"] & 0xFFFFFFFF
    new_entries = list(entries)
    if args.undo:
        if idx is not None:
            del new_entries[idx]
    else:
        fresh = build_entry(args, exe_q, start_q, appid)
        if idx is None:
            new_entries.append(fresh)
        else:
            merged = dict(entries[idx])
            keep = {k: merged[k] for k in ("icon", "LastPlayTime", "tags") if k in merged}
            merged.update(fresh)
            merged.update(keep)
            new_entries[idx] = merged
    sc_changed = new_entries != entries
    if sc_changed:
        data[key] = {str(i): e for i, e in enumerate(new_entries)}
        print(f"{tag}{'remove' if args.undo else 'write'} shortcut '{args.name}' in {sc_path}")
        if not dry:
            backup(sc_path)
            atomic_write(sc_path, vdf.binary_dumps(data))
    else:
        print(f"shortcuts.vdf unchanged: {sc_path}")

    # config.vdf
    cfg = load_config(cfg_path)
    before = vdf.dumps(cfg)
    stale = {str(a) for a in (appid, old_appid) if a is not None}
    if args.undo:
        m = compat_mapping(cfg, create=False)
        if m is not None:
            for a in stale:
                m.pop(a, None)
    else:
        m = compat_mapping(cfg, create=True)
        if old_appid is not None and old_appid != appid:
            m.pop(str(old_appid), None)
        m[str(appid)] = {"name": args.compat_tool, "config": "", "priority": "250"}
    if vdf.dumps(cfg) != before or (not cfg_path.exists() and not args.undo):
        print(f"{tag}{'remove' if args.undo else 'set'} CompatToolMapping[{appid}] in {cfg_path}")
        if not dry:
            backup(cfg_path)
            atomic_write(cfg_path, vdf.dumps(cfg, pretty=True).encode("utf-8"))
    else:
        print(f"config.vdf unchanged: {cfg_path}")

    if not args.undo:
        print(f"appid: {appid}")
        print(f"gameid: {compute_gameid(appid)}")
        print(f"compatdata: {root / 'steamapps' / 'compatdata' / str(appid)}")
        print(f"launch: steam steam://rungameid/{compute_gameid(appid)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
