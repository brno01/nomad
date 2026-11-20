"""Tests for the generated Steam Input layout (ragnarok-apex3.vdf)."""

import subprocess
import sys
from pathlib import Path

import pytest
import vdf

STEAM_DIR = Path(__file__).resolve().parents[1] / "steam"
VDF_PATH = STEAM_DIR / "ragnarok-apex3.vdf"
SCRIPT = STEAM_DIR / "build_layout.py"

CTRL, ALT = "key_press LEFT_CONTROL", "key_press LEFT_ALT"


@pytest.fixture(scope="module")
def cfg():
    # VDFDict keeps duplicate keys (several "binding" entries per activator).
    root = vdf.loads(VDF_PATH.read_text(encoding="utf-8"), mapper=vdf.VDFDict, merge_duplicate_keys=False)
    return root["controller_mappings"]


def _preset(cfg, name):
    for _, p in cfg.items():
        if isinstance(p, dict) and p.get("name") == name and "group_source_bindings" in p:
            return p
    raise AssertionError(f"preset {name!r} not found")


def _group(cfg, preset_name, source):
    preset = _preset(cfg, preset_name)
    gid = next(
        (k for k, v in preset["group_source_bindings"].items() if v == f"{source} active"),
        None,
    )
    assert gid is not None, f"{preset_name} has no group for {source}"
    for key, g in cfg.items():
        if key == "group" and g["id"] == gid:
            return g
    raise AssertionError(f"group {gid} missing")


def bindings(cfg, preset, source, input_name):
    g = _group(cfg, preset, source)
    act = g["inputs"][input_name]["activators"]["Full_Press"]["bindings"]
    return list(act.get_all_for("binding"))


def test_top_level_structure(cfg):
    assert cfg["version"] == "3"
    assert cfg["title"] == "Ragnarok Online - Apex 3 (stream)"
    assert cfg["controller_type"] == "controller_xbox360"
    for key in ("description", "actions", "action_layers", "group", "preset", "settings"):
        assert key in cfg, key
    assert [p["name"] for _, p in cfg.items() if isinstance(p, dict) and "group_source_bindings" in p] == [
        "Default",
        "Preset_1000001",
        "Preset_1000002",
    ]


def test_layers_declared(cfg):
    layers = cfg["action_layers"]
    assert layers["Preset_1000001"]["title"] == "Fileira 2"
    assert layers["Preset_1000002"]["title"] == "Janelas"
    for name in ("Preset_1000001", "Preset_1000002"):
        assert layers[name]["set_layer"] == "1"
        assert layers[name]["parent_set_name"] == "Default"


BASE_EXPECTED = [
    ("button_diamond", "button_a", ["key_press F1"]),
    ("button_diamond", "button_b", ["key_press F2"]),
    ("button_diamond", "button_x", ["key_press F3"]),
    ("button_diamond", "button_y", ["key_press F4"]),
    ("dpad", "dpad_north", ["key_press F5"]),
    ("dpad", "dpad_east", ["key_press F6"]),
    ("dpad", "dpad_south", ["key_press F7"]),
    ("dpad", "dpad_west", ["key_press F8"]),
    ("switch", "right_bumper", ["key_press F9"]),
    ("switch", "button_menu", ["key_press ESCAPE"]),
    ("switch", "button_escape", ["controller_action SHOW_KEYBOARD", "key_press RETURN"]),
    ("switch", "left_bumper", ["controller_action HOLD_LAYER 2 0 0"]),
    ("left_trigger", "click", ["controller_action HOLD_LAYER 1 0 0"]),
    ("right_trigger", "click", ["mouse_button LEFT"]),
    ("joystick", "click", ["key_press INSERT"]),
    ("joystick", "edge", ["mouse_button LEFT"]),
    ("right_joystick", "click", ["mouse_button RIGHT"]),
]


@pytest.mark.parametrize("source,inp,expected", BASE_EXPECTED)
def test_base_bindings(cfg, source, inp, expected):
    assert bindings(cfg, "Default", source, inp) == expected


def test_base_stick_modes(cfg):
    assert _group(cfg, "Default", "joystick")["mode"] == "mouse_region"
    assert _group(cfg, "Default", "right_joystick")["mode"] == "joystick_mouse"


ROW2_EXPECTED = [
    ("button_diamond", "button_a", 1),
    ("button_diamond", "button_b", 2),
    ("button_diamond", "button_x", 3),
    ("button_diamond", "button_y", 4),
    ("dpad", "dpad_north", 5),
    ("dpad", "dpad_east", 6),
    ("dpad", "dpad_south", 7),
    ("dpad", "dpad_west", 8),
    ("switch", "right_bumper", 9),
]


@pytest.mark.parametrize("source,inp,slot", ROW2_EXPECTED)
def test_row2_layer(cfg, source, inp, slot):
    assert bindings(cfg, "Preset_1000001", source, inp) == [CTRL, f"key_press F{slot}"]


def test_row2_inherits_rest(cfg):
    preset = _preset(cfg, "Preset_1000001")["group_source_bindings"]
    sources = {v.split()[0] for v in preset.values()}
    assert sources == {"button_diamond", "dpad", "switch"}
    # Switch group keeps Start/Back/LB from base.
    assert bindings(cfg, "Preset_1000001", "switch", "button_menu") == ["key_press ESCAPE"]


WINDOWS_EXPECTED = [
    ("button_diamond", "button_a", [ALT, "key_press E"]),
    ("button_diamond", "button_b", [ALT, "key_press S"]),
    ("button_diamond", "button_x", [ALT, "key_press Q"]),
    ("button_diamond", "button_y", [ALT, "key_press A"]),
    ("dpad", "dpad_north", [CTRL, "key_press TAB"]),
    ("dpad", "dpad_east", [ALT, "key_press Z"]),
    ("dpad", "dpad_south", [ALT, "key_press G"]),
    ("dpad", "dpad_west", [ALT, "key_press U"]),
    ("right_joystick", "dpad_north", ["mouse_wheel SCROLL_UP"]),
    ("right_joystick", "dpad_south", ["mouse_wheel SCROLL_DOWN"]),
    ("right_joystick", "click", ["mouse_button RIGHT"]),
]


@pytest.mark.parametrize("source,inp,expected", WINDOWS_EXPECTED)
def test_windows_layer(cfg, source, inp, expected):
    assert bindings(cfg, "Preset_1000002", source, inp) == expected


def test_windows_right_stick_is_not_cursor(cfg):
    assert _group(cfg, "Preset_1000002", "right_joystick")["mode"] != "joystick_mouse"


def test_check_passes():
    r = subprocess.run([sys.executable, "-I", str(SCRIPT), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_check_detects_drift(tmp_path):
    # Run the generator from a copy whose committed VDF differs.
    script = tmp_path / "build_layout.py"
    script.write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
    (tmp_path / "ragnarok-apex3.vdf").write_text("stale\n", encoding="utf-8")
    r = subprocess.run([sys.executable, "-I", str(script), "--check"], capture_output=True, text=True)
    assert r.returncode == 1
