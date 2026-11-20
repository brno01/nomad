"""Tests for ragnarok-stream/antimicrox/build_profile.py (stdlib only)."""
import importlib.util
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent / "antimicrox"
SCRIPT = DIR / "build_profile.py"


def load():
    spec = importlib.util.spec_from_file_location("build_profile", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bp = load()
ROOT = ET.fromstring(bp.build())


def slots(el):
    return [(s.findtext("mode"), s.findtext("code")) for s in el.find("slots")] if el.find("slots") is not None else []


def the_set(n):
    return ROOT.find(f"sets/set[@index='{n}']")


def key(name):
    return ("keyboard", f"0x{bp.KEYS[name]:x}")


def combo(*names):
    return [key(n) for n in names]


MOUSE_LEFT = [("mousebutton", "1")]
MOUSE_RIGHT = [("mousebutton", "3")]
WHEEL_UP, WHEEL_DOWN = [("mousebutton", "4")], [("mousebutton", "5")]

BUTTON_INDEX = {"A": 1, "B": 2, "X": 3, "Y": 4, "Back": 5, "Start": 7, "L3": 8, "R3": 9, "LB": 10, "RB": 11}
DPAD_INDEX = {"up": 1, "right": 2, "down": 4, "left": 8}


def button(st, name):
    el = st.find(f"button[@index='{BUTTON_INDEX[name]}']")
    return el


def dpad(st):
    return {d: slots(b) for d, i in DPAD_INDEX.items() for b in st.findall(f"dpad/dpadbutton[@index='{i}']")}


def trigger(st, name):
    idx = {"LT": 5, "RT": 6}[name]
    return st.find(f"trigger[@index='{idx}']/triggerbutton")


def setchange(el):
    return el.findtext("setselect"), el.findtext("setselectcondition")


def test_root_is_a_game_controller_profile_with_four_sets():
    assert ROOT.tag == "gamecontroller"
    assert ROOT.get("configversion") == "19"
    assert [s.get("index") for s in ROOT.find("sets")] == ["1", "2", "3", "4"]


def test_hotkey_rows_are_one_data_table():
    # row 1 = keys 1..9, row 2 = Shift+1..9 (the client's UserKeys_s.lua custom hotkeys)
    assert bp.ROW1 == [["1"], ["2"], ["3"], ["4"], ["5"], ["6"], ["7"], ["8"], ["9"]]
    assert bp.ROW2 == [["Shift", n] for n in "123456789"]
    assert bp.KEYS["1"] == 0x31 and bp.KEYS["9"] == 0x39 and bp.KEYS["Shift"] == 0x01000020


def test_set1_exact_mappings():
    st = the_set(1)
    assert slots(button(st, "A")) == MOUSE_LEFT
    assert slots(button(st, "B")) == combo("Esc")
    assert slots(button(st, "X")) == combo("Return")
    assert slots(button(st, "Y")) == combo("Insert")
    assert slots(trigger(st, "LT")) == MOUSE_RIGHT
    assert dpad(st) == {"up": combo("1"), "right": combo("2"), "down": combo("3"), "left": combo("4")}
    assert slots(button(st, "Start")) == combo("Esc")
    assert slots(button(st, "Back")) == combo("Alt", "E")
    assert button(st, "L3") is None and button(st, "R3") is None
    assert button(st, "RB").findtext("setselect") == "4"
    assert setchange(trigger(st, "RT")) == ("2", "while-held")
    assert setchange(button(st, "LB")) == ("3", "while-held")
    assert setchange(button(st, "RB")) == ("4", "while-held")
    assert slots(trigger(st, "RT")) == []


def test_set2_row1_rest():
    st = the_set(2)
    assert [slots(button(st, n)) for n in "A B X Y".split()] == [combo("5"), combo("6"), combo("7"), combo("8")]
    assert slots(button(st, "RB")) == combo("9")
    assert dpad(st) == {"up": combo("1"), "right": combo("2"), "down": combo("3"), "left": combo("4")}
    assert slots(trigger(st, "LT")) == MOUSE_RIGHT
    assert setchange(trigger(st, "RT")) == ("1", "while-held")  # reciprocal: back to set 1


def test_set3_row2_shift():
    st = the_set(3)
    assert [slots(button(st, n)) for n in "A B X Y".split()] == [
        combo("Shift", "5"), combo("Shift", "6"), combo("Shift", "7"), combo("Shift", "8")]
    assert slots(button(st, "RB")) == combo("Shift", "9")
    assert dpad(st) == {"up": combo("Shift", "1"), "right": combo("Shift", "2"),
                        "down": combo("Shift", "3"), "left": combo("Shift", "4")}
    assert slots(trigger(st, "LT")) == MOUSE_RIGHT
    assert setchange(button(st, "LB")) == ("1", "while-held")


def test_set4_windows():
    st = the_set(4)
    assert [slots(button(st, n)) for n in "A B X Y".split()] == [
        combo("Alt", "E"), combo("Alt", "S"), combo("Alt", "Q"), combo("Alt", "A")]
    assert dpad(st) == {"up": combo("Ctrl", "Tab"), "right": combo("Alt", "Z"),
                        "down": combo("Alt", "G"), "left": combo("Alt", "U")}
    assert slots(trigger(st, "LT")) == MOUSE_RIGHT
    assert setchange(button(st, "RB")) == ("1", "while-held")


def test_sticks_are_the_same_in_every_set():
    for n in (1, 2, 3, 4):
        st = the_set(n)
        left = st.find("stick[@index='1']")
        assert left.findtext("deadZone") == str(bp.STICK_DEADZONE)
        assert {b.get("index"): slots(b) for b in left.findall("stickbutton")} == {
            "1": [("mousemovement", "1")], "3": [("mousemovement", "4")],
            "5": [("mousemovement", "2")], "7": [("mousemovement", "3")]}
        for b in left.findall("stickbutton"):
            assert b.findtext("mouseacceleration") == "precision"
            assert b.findtext("mousespeedx") == str(bp.LEFT_STICK_SPEED)
            assert b.findtext("mousespeedy") == str(bp.LEFT_STICK_SPEED)
            assert b.find("mousemode") is None  # relative, never spring
        right = st.find("stick[@index='2']")
        assert {b.get("index"): slots(b) for b in right.findall("stickbutton")} == {"1": WHEEL_UP, "5": WHEEL_DOWN}


def test_dead_zone_is_about_15_percent_of_the_axis():
    assert abs(bp.STICK_DEADZONE / 32767 - 0.15) < 0.01


def test_no_spring_left_anywhere():
    text = bp.build()
    assert "spring" not in text
    assert not hasattr(bp, "build_spring")


def test_qt_key_codes():
    assert bp.KEYS["Esc"] == 0x1000000 and bp.KEYS["Return"] == 0x1000004 and bp.KEYS["E"] == 0x45
    assert bp.KEYS["Insert"] == 0x1000006 and bp.KEYS["Ctrl"] == 0x1000021 and bp.KEYS["Alt"] == 0x1000023


def run(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True)


def test_check_passes_for_the_committed_profile_and_fails_when_stale(tmp_path):
    assert run("--check").returncode == 0
    assert run("--no-spring").returncode != 0  # the flag is gone
    out = tmp_path / "x.amgp"
    assert run("--check", "--out", str(out)).returncode == 1  # missing
    assert run("--out", str(out)).returncode == 0
    assert run("--check", "--out", str(out)).returncode == 0
    out.write_text(out.read_text() + "<!-- edited -->")
    r = run("--check", "--out", str(out))
    assert r.returncode == 1 and "stale" in r.stderr
