"""Turn on "Enable Steam Input for Xbox controllers" (key SteamController_XBoxSupport = "1").

Run (Steam CLOSED, it rewrites its configs on exit):
    uv run --no-project --with vdf python -I ragnarok-stream/steam/enable_xbox_support.py [--dry-run]

UNCERTAIN: Valve does not document where this key lives. Community posts place it near the
bottom of a Steam config file (steamcommunity.com/app/353370/discussions/0/3802778829233916867),
and mention both config.vdf and localconfig.vdf. So this script searches, in order,
  <steam-root>/config/config.vdf
  <steam-root>/userdata/<account>/config/localconfig.vdf
and updates the key wherever it already exists; if it is in neither, it adds it to
InstallConfigStore > Software > Valve > Steam of config.vdf. If the layout still does not pick up
the Xbox pad after that, flip the toggle in the UI (Settings > Controller > Enable Steam Input
for Xbox Controllers; see steam/INSTALL-LAYOUT.md section 0). Backups: <file>.antes-ragnarok.
The undo is to flip the same toggle off; this script has no --undo on purpose.
"""
import argparse
import importlib.util
import sys
from pathlib import Path

try:
    import vdf
except ImportError:  # pragma: no cover
    sys.exit("error: the 'vdf' module is missing; run with: uv run --no-project --with vdf python -I ...")

KEY = "SteamController_XBoxSupport"


def _load_add_shortcut():
    path = Path(__file__).resolve().with_name("add_shortcut.py")
    spec = importlib.util.spec_from_file_location("add_shortcut", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def find_key_anywhere(node, key):
    """Return the dict that directly holds `key` (case-insensitive), searching depth-first."""
    if not isinstance(node, dict):
        return None, None
    k = next((x for x in node if isinstance(x, str) and x.lower() == key.lower()), None)
    if k is not None:
        return node, k
    for child in node.values():
        holder, hk = find_key_anywhere(child, key)
        if holder is not None:
            return holder, hk
    return None, None


def main(argv=None):
    a = _load_add_shortcut()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--steam-root", default="~/.local/share/Steam")
    ap.add_argument("--account-id")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--allow-running", action="store_true", help="testing only")
    args = ap.parse_args(argv)

    root = Path(args.steam_root).expanduser()
    if a.steam_running() and not args.allow_running:
        if args.dry_run:
            print("warning: Steam is running; a real run would be refused", file=sys.stderr)
        else:
            print("error: Steam is running; close it completely (File > Exit) and retry. "
                  "Steam overwrites these files on exit.", file=sys.stderr)
            return a.EXIT_STEAM_RUNNING

    account = a.pick_account(root, args.account_id)
    cfg_path = root / "config" / "config.vdf"
    lc_path = root / "userdata" / account / "config" / "localconfig.vdf"
    tag = "would " if args.dry_run else ""

    docs = {}
    for p in (cfg_path, lc_path):
        if p.exists():
            docs[p] = vdf.loads(p.read_text(encoding="utf-8"))

    target = None
    for p, doc in docs.items():
        holder, k = find_key_anywhere(doc, KEY)
        if holder is not None:
            target = p
            if holder[k] == "1":
                print(f"{KEY} unchanged (already 1): {p}")
                return 0
            holder[k] = "1"
            break
    else:
        target = cfg_path
        doc = docs.get(cfg_path)
        if doc is None:
            doc = docs[cfg_path] = {}
        node = doc
        for name in ("InstallConfigStore", "Software", "Valve", "Steam"):
            node = a.get_or_create(node, name)
        node[KEY] = "1"

    print(f"{tag}set {KEY} = 1 in {target}")
    if not args.dry_run:
        a.backup(target)
        a.atomic_write(target, vdf.dumps(docs[target], pretty=True).encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
