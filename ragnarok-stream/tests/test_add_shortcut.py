"""Tests for ragnarok-stream/steam/add_shortcut.py (temp dirs only, no real Steam)."""
import importlib.util
import os
import subprocess
import sys
import zlib
from pathlib import Path

import pytest
import vdf

SCRIPT = Path(__file__).resolve().parent.parent / "steam" / "add_shortcut.py"
NAME = "Ragnarok (stream)"
EXE = "/games/ro/ragnarok.exe"
EXE2 = "/games/ro2/other.exe"
ACCOUNT = "12345678"


def load_module():
    spec = importlib.util.spec_from_file_location("add_shortcut", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def other_entry():
    return {
        "appid": -1234567,
        "AppName": "Other Game",
        "Exe": '"/opt/other/other"',
        "StartDir": '"/opt/other/"',
        "icon": "",
        "ShortcutPath": "",
        "LaunchOptions": "-x",
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 42,
        "FlatpakAppID": "",
        "tags": {"0": "fav"},
    }


CONFIG_TEXT = """"InstallConfigStore"
{
\t"Software"
\t{
\t\t"valve"
\t\t{
\t\t\t"steam"
\t\t\t{
\t\t\t\t"AutoUpdateWindowStart"\t\t"-1"
\t\t\t\t"CompatToolMapping"
\t\t\t\t{
\t\t\t\t\t"570"
\t\t\t\t\t{
\t\t\t\t\t\t"name"\t\t"proton_9"
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"250"
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t}
\t}
}
"""


def sc_file(steam):
    return steam / "userdata" / ACCOUNT / "config" / "shortcuts.vdf"


@pytest.fixture
def steam(tmp_path):
    root = tmp_path / "Steam"
    sc_file(root).parent.mkdir(parents=True)
    sc_file(root).write_bytes(vdf.binary_dumps({"shortcuts": {"0": other_entry()}}))
    (root / "config").mkdir()
    (root / "config" / "config.vdf").write_text(CONFIG_TEXT)
    return root


@pytest.fixture
def env():
    e = dict(os.environ)
    e["STEAM_RUNNING_CHECK"] = "0"
    return e


def run(steam, env, *args, exe=EXE):
    cmd = [sys.executable, "-I", str(SCRIPT), "--steam-root", str(steam)]
    if exe is not None:
        cmd += ["--exe", exe]
    cmd += list(args)
    return subprocess.run(cmd, env=env, capture_output=True, text=True)


def shortcuts(steam):
    return vdf.binary_loads(sc_file(steam).read_bytes())["shortcuts"]


def config(steam):
    return vdf.loads((steam / "config" / "config.vdf").read_text())


def mapping(steam):
    return config(steam)["InstallConfigStore"]["Software"]["valve"]["steam"][
        "CompatToolMapping"
    ]


def appid_for(exe=EXE):
    return zlib.crc32(f'"{exe}"{NAME}'.encode()) | 0x80000000


def test_appid_math_known_value():
    m = load_module()
    # crc32("123456789") == 0xCBF43926 (standard check value)
    appid = m.compute_appid("12345", "6789")
    assert appid == 0xCBF43926 | 0x80000000 == 3421780262
    assert m.compute_gameid(appid) == (3421780262 << 32) | 0x02000000
    assert m.to_signed32(appid) == 3421780262 - 2**32


def test_add(steam, env):
    r = run(steam, env)
    assert r.returncode == 0, r.stderr
    sc = shortcuts(steam)
    assert list(sc) == ["0", "1"]
    assert sc["0"]["AppName"] == "Other Game"
    assert sc["0"]["LastPlayTime"] == 42
    e = sc["1"]
    appid = appid_for()
    assert e["appid"] == appid - 2**32
    assert e["AppName"] == NAME
    assert e["Exe"] == f'"{EXE}"'
    assert e["StartDir"] == '"/games/ro"'
    assert e["AllowOverlay"] == 1 and e["IsHidden"] == 0
    assert e["tags"] == {}
    m = mapping(steam)
    assert m["570"]["name"] == "proton_9"
    assert m[str(appid)] == {"name": "proton_experimental", "config": "", "priority": "250"}
    assert f"appid: {appid}" in r.stdout
    assert f"gameid: {(appid << 32) | 0x02000000}" in r.stdout
    assert str(steam / "steamapps" / "compatdata" / str(appid)) in r.stdout


def test_idempotent(steam, env):
    run(steam, env)
    before = sc_file(steam).read_bytes()
    cfg_before = (steam / "config" / "config.vdf").read_text()
    r = run(steam, env)
    assert r.returncode == 0
    assert len(shortcuts(steam)) == 2
    assert sc_file(steam).read_bytes() == before
    assert (steam / "config" / "config.vdf").read_text() == cfg_before


def test_update_exe_moves_mapping(steam, env):
    run(steam, env)
    old = appid_for()
    r = run(steam, env, "--compat-tool", "GE-Proton9", exe=EXE2)
    assert r.returncode == 0, r.stderr
    sc = shortcuts(steam)
    assert len(sc) == 2
    new = appid_for(EXE2)
    assert sc["1"]["Exe"] == f'"{EXE2}"'
    assert sc["1"]["appid"] == new - 2**32
    m = mapping(steam)
    assert str(old) not in m
    assert m[str(new)]["name"] == "GE-Proton9"
    assert "570" in m


def test_undo(steam, env):
    run(steam, env)
    r = run(steam, env, "--undo")
    assert r.returncode == 0, r.stderr
    assert shortcuts(steam) == {"0": other_entry()}
    assert list(mapping(steam)) == ["570"]
    # second undo is a no-op
    assert run(steam, env, "--undo").returncode == 0
    assert shortcuts(steam) == {"0": other_entry()}


def test_undo_without_files_creates_nothing(tmp_path, env):
    root = tmp_path / "S"
    (root / "userdata" / ACCOUNT).mkdir(parents=True)
    assert run(root, env, "--undo").returncode == 0
    assert not (root / "config").exists()
    assert not sc_file(root).exists()


def test_dry_run_writes_nothing(steam, env):
    b, c = sc_file(steam).read_bytes(), (steam / "config" / "config.vdf").read_text()
    r = run(steam, env, "--dry-run")
    assert r.returncode == 0
    assert "would" in r.stdout.lower()
    assert sc_file(steam).read_bytes() == b
    assert (steam / "config" / "config.vdf").read_text() == c
    assert not list(steam.rglob("*.antes-ragnarok"))


def test_refuses_when_steam_running(steam, tmp_path):
    proc = tmp_path / "proc"
    (proc / "999").mkdir(parents=True)
    (proc / "999" / "comm").write_text("steamwebhelper\n")
    e = dict(os.environ)
    e.pop("STEAM_RUNNING_CHECK", None)
    e["STEAM_PROC_DIR"] = str(proc)
    r = run(steam, e)
    assert r.returncode == 3
    assert "Steam is running" in r.stderr
    assert len(shortcuts(steam)) == 1


def test_not_refused_when_steam_absent(steam, tmp_path):
    proc = tmp_path / "proc"
    (proc / "1").mkdir(parents=True)
    (proc / "1" / "comm").write_text("bash\n")
    e = dict(os.environ)
    e.pop("STEAM_RUNNING_CHECK", None)
    e["STEAM_PROC_DIR"] = str(proc)
    assert run(steam, e).returncode == 0


def test_backups(steam, env):
    b, c = sc_file(steam).read_bytes(), (steam / "config" / "config.vdf").read_text()
    run(steam, env)
    bs = sc_file(steam).with_name("shortcuts.vdf.antes-ragnarok")
    bc = steam / "config" / "config.vdf.antes-ragnarok"
    assert bs.read_bytes() == b
    assert bc.read_text() == c
    run(steam, env, exe=EXE2)  # existing backup must not be overwritten
    assert bs.read_bytes() == b
    assert bc.read_text() == c


def test_creates_missing_files(tmp_path, env):
    root = tmp_path / "S"
    (root / "userdata" / ACCOUNT).mkdir(parents=True)
    r = run(root, env)
    assert r.returncode == 0, r.stderr
    assert len(shortcuts(root)) == 1
    cfg = vdf.loads((root / "config" / "config.vdf").read_text())
    m = cfg["InstallConfigStore"]["Software"]["Valve"]["Steam"]["CompatToolMapping"]
    assert str(appid_for()) in m


def test_account_autodetect_and_ambiguity(steam, env):
    assert run(steam, env, "--dry-run").returncode == 0  # one dir: auto-detected
    (steam / "userdata" / "999").mkdir()
    assert run(steam, env).returncode == 2
    assert run(steam, env, "--account-id", ACCOUNT).returncode == 0


def test_two_accounts_without_account_id_exits_2(tmp_path):
    root = tmp_path / "steam"
    (root / "userdata" / "111").mkdir(parents=True)
    (root / "userdata" / "222").mkdir(parents=True)
    r = subprocess.run(
        [sys.executable, "-I", str(SCRIPT), "--steam-root", str(root), "--exe", EXE],
        capture_output=True, text=True,
        env={"STEAM_RUNNING_CHECK": "0", "PATH": os.environ.get("PATH", "")},
    )
    assert r.returncode == 2
    assert "--account-id" in r.stderr
    assert not (root / "config").exists()
