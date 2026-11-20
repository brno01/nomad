"""Tests for ragnarok-stream/steam/enable_xbox_support.py (temp dirs only)."""
import subprocess
import sys
from pathlib import Path

import vdf

SCRIPT = Path(__file__).resolve().parent.parent / "steam" / "enable_xbox_support.py"
ACCOUNT = "777"
KEY = "SteamController_XBoxSupport"


def run(root, *extra):
    return subprocess.run(
        [sys.executable, "-I", str(SCRIPT), "--steam-root", str(root), "--account-id", ACCOUNT,
         "--allow-running", *extra],
        capture_output=True, text=True,
    )


def write(path, tree):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(vdf.dumps(tree, pretty=True), encoding="utf-8")


def steam_node(tree):
    return tree["InstallConfigStore"]["Software"]["Valve"]["Steam"]


def make_config(root, steam=None):
    write(root / "config" / "config.vdf",
          {"InstallConfigStore": {"Software": {"Valve": {"Steam": dict(steam or {"x": "y"})}}}})


def test_sets_in_config_vdf_when_key_absent_everywhere(tmp_path):
    make_config(tmp_path)
    r = run(tmp_path)
    assert r.returncode == 0, r.stderr
    cfg = vdf.loads((tmp_path / "config" / "config.vdf").read_text())
    assert steam_node(cfg)[KEY] == "1"
    assert steam_node(cfg)["x"] == "y"
    assert (tmp_path / "config" / "config.vdf.antes-ragnarok").exists()


def test_updates_where_found_and_is_idempotent(tmp_path):
    make_config(tmp_path)
    lc = tmp_path / "userdata" / ACCOUNT / "config" / "localconfig.vdf"
    write(lc, {"UserLocalConfigStore": {KEY: "0", "other": "1"}})
    assert run(tmp_path).returncode == 0
    assert vdf.loads(lc.read_text())["UserLocalConfigStore"][KEY] == "1"
    cfg = vdf.loads((tmp_path / "config" / "config.vdf").read_text())
    assert KEY not in steam_node(cfg)
    before = lc.read_bytes()
    r = run(tmp_path)
    assert "unchanged" in r.stdout
    assert lc.read_bytes() == before


def test_dry_run_writes_nothing(tmp_path):
    make_config(tmp_path)
    cfg = tmp_path / "config" / "config.vdf"
    before = cfg.read_bytes()
    r = run(tmp_path, "--dry-run")
    assert r.returncode == 0
    assert "would" in r.stdout
    assert cfg.read_bytes() == before


def test_refuses_when_steam_runs(tmp_path):
    make_config(tmp_path)
    proc = tmp_path / "proc" / "42"
    proc.mkdir(parents=True)
    (proc / "comm").write_text("steam\n")
    r = subprocess.run(
        [sys.executable, "-I", str(SCRIPT), "--steam-root", str(tmp_path), "--account-id", ACCOUNT],
        capture_output=True, text=True,
        env={"STEAM_PROC_DIR": str(tmp_path / "proc"), "PATH": "/usr/bin"},
    )
    assert r.returncode == 3
    assert "Steam is running" in r.stderr
