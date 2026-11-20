"""Generate the AntiMicroX profile (ragnarok.amgp) for Ragnarok over Sunshine/Moonlight.

Run (stdlib only):
    python3 -I ragnarok-stream/antimicrox/build_profile.py [--out FILE] [--check]

Targets an Xbox 360 / SDL GameController (the virtual pad Sunshine exposes with gamepad = x360).
--check exits 1 if the file on disk differs from what this script generates.

The client uses CUSTOM hotkeys (savedata/UserKeys_s.lua): row 1 = keys 1..9, row 2 = Shift+1..9, row 3 =
numpad 1..9; F1..F9 are bound to nothing. Console semantics: A confirms (left click), B goes back (Esc).

Sets (all of them hold the same sticks and LT):
  1 base:      A left click, B Esc, X Return, Y Insert, D-pad 1..4, Start Esc, Back Alt+E;
               RT held -> set 2, LB held -> set 3, RB held -> set 4
  2 (RT held)  rest of row 1: A..Y = 5..8, RB = 9, D-pad 1..4
  3 (LB held)  row 2: D-pad Shift+1..4, A..Y Shift+5..8, RB Shift+9
  4 (RB held)  windows: A/B/X/Y Alt+E/S/Q/A, D-pad Ctrl+Tab / Alt+Z / Alt+G / Alt+U
  LT = right mouse button (hold + left stick rotates the camera). Left stick = relative mouse with the
  "Enhanced Precision" curve (tuning knob: LEFT_STICK_SPEED). Right stick up/down = mouse wheel (zoom); left/right
  are unbound on purpose (the horizontal wheel is far too fast on uinput, AntiMicroX issue #1024).
  Spring mode is NOT used: it does not move the pointer on KDE Wayland (the uinput device looks like a pen,
  AntiMicroX issue #521).

Schema, read from AntiMicroX's own XML reader/writer (master, config version 19, app 3.6.2):
  https://github.com/AntiMicroX/antimicrox/tree/master/src/xml   (inputdevicexml, setjoystickxml,
      joybuttonxml, joybuttonslotxml, joyaxisxml, joydpadxml)
  https://github.com/AntiMicroX/antimicrox/blob/master/src/gamecontroller/gamecontrollerset.cpp
      (SDL button numbering, sticks, vdpad, triggers of a game controller set)
  https://github.com/AntiMicroX/antimicrox/blob/master/src/globalvariables.cpp   (element names)
  https://github.com/AntiMicroX/antimicrox/blob/master/src/joycontrolstickdirectionstype.h  (stick directions)
  https://github.com/AntiMicroX/antimicrox/blob/master/src/gui/joybuttonslot.h   (mouse codes)
Layout of the file:
  <gamecontroller configversion appversion><sdlname/><sets><set index="1..4">
     <stick index="1|2"><deadZone/><stickbutton index="1|3|5|7">   up/right/down/left (standard mode)
     <dpad index="1"><dpadbutton index="1|2|4|8">        up/right/down/left (virtual dpad of the controller)
     <trigger index="5|6"><throttle>positivehalf</throttle><triggerbutton index="2">   LT / RT
     <button index="n">  n = SDL_CONTROLLER_BUTTON_* + 1 (A=1 B=2 X=3 Y=4 Back=5 Guide=6 Start=7 L3=8 R3=9 LB=10 RB=11)
  each button element holds: [mousespeedx/y + mouseacceleration] [setselect + setselectcondition]
  and <slots><slot><code/><mode/></slot>...</slots>; modes used: keyboard (code = Qt::Key as 0x hex),
  mousebutton (1 left, 3 right, 4 wheel up, 5 wheel down), mousemovement (1 up, 2 down, 3 left, 4 right).
Several slots on one button are pressed together and held while the button is held (so Shift+1 = two keyboard slots).
Set change "while held": <setselect>N</setselect><setselectcondition>while-held</setselectcondition>; the
destination set carries the reciprocal button back to set 1, as AntiMicroX itself saves it.

# UNCERTAIN: (also listed in ragnarok-stream/README.md)
# UNCERTAIN: nothing here was loaded in a real AntiMicroX; the schema is taken from the source code.
# UNCERTAIN: mousespeed units (1..200 in the GUI, default 50) and the "precision" curve feel: tune LEFT_STICK_SPEED.
# UNCERTAIN: stick deadZone is in raw axis units (0..32767); 4915 = 15%.
# UNCERTAIN: sets 2-4 carry only the buttons listed above (Start/Back/Y... of the base set are not repeated).
"""
import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

CONFIG_VERSION = "19"
APP_VERSION = "3.6.2"
HERE = Path(__file__).resolve().parent

# ---- declarative table ----------------------------------------------------------------

# Qt::Key values (what AntiMicroX writes in <code>).
KEYS = {
    "Esc": 0x01000000, "Tab": 0x01000001, "Return": 0x01000004, "Insert": 0x01000006,
    "Shift": 0x01000020, "Ctrl": 0x01000021, "Alt": 0x01000023,
    **{str(i): 0x30 + i for i in range(1, 10)},
    **{c: ord(c) for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"},
}
MOUSE_LEFT, MOUSE_RIGHT, WHEEL_UP, WHEEL_DOWN = 1, 3, 4, 5
MOVE = {"up": 1, "down": 2, "left": 3, "right": 4}

BUTTON_INDEX = {"A": 1, "B": 2, "X": 3, "Y": 4, "Back": 5, "Guide": 6, "Start": 7, "L3": 8, "R3": 9, "LB": 10, "RB": 11}
DPAD = {"up": 1, "right": 2, "down": 4, "left": 8}      # <dpadbutton index>
STICK_DIR = {"up": 1, "right": 3, "down": 5, "left": 7}  # <stickbutton index>, standard mode
TRIGGER = {"LT": 5, "RT": 6}                              # <trigger index> (SDL axis + 1)

# The client's hotkey rows (UserKeys_s.lua): slot i (0-based) of a row is the key combo ROW[i].
ROW1 = [[str(n)] for n in range(1, 10)]
ROW2 = [["Shift", str(n)] for n in range(1, 10)]
# Which pad control fires which hotkey slot (0-based) when a row is active.
HOTKEY_SLOT = {"dpad:up": 0, "dpad:right": 1, "dpad:down": 2, "dpad:left": 3,
               "A": 4, "B": 5, "X": 6, "Y": 7, "RB": 8}

# Tuning knobs for the left stick (relative mouse, "Enhanced Precision" curve).
LEFT_STICK_SPEED = 25         # mousespeedx/y, AntiMicroX default is 50; raise it for a faster pointer
STICK_DEADZONE = 4915         # ~15% of 32767

# Set number -> {button/trigger name: set to switch to while held}. Sets 2..4 carry the way back.
SET_CHANGE = {
    1: {"RT": 2, "LB": 3, "RB": 4},
    2: {"RT": 1},
    3: {"LB": 1},
    4: {"RB": 1},
}


def keys(*names):
    return [("key", n) for n in names]


def row(row_keys, targets):
    return {t: keys(*row_keys[HOTKEY_SLOT[t]]) for t in targets}


def build_sets():
    """Return {set_number: {target: slots}}; target is a button name, trigger name or 'dpad:<dir>'."""
    dpad = [f"dpad:{d}" for d in DPAD]
    base_lt = {"LT": [("mouse", MOUSE_RIGHT)]}
    s1 = {**base_lt, **row(ROW1, dpad),
          "A": [("mouse", MOUSE_LEFT)], "B": keys("Esc"), "X": keys("Return"), "Y": keys("Insert"),
          "Start": keys("Esc"), "Back": keys("Alt", "E")}
    s2 = {**base_lt, **row(ROW1, dpad + ["A", "B", "X", "Y", "RB"])}
    s3 = {**base_lt, **row(ROW2, dpad + ["A", "B", "X", "Y", "RB"])}
    s4 = {**base_lt,
          "A": keys("Alt", "E"), "B": keys("Alt", "S"), "X": keys("Alt", "Q"), "Y": keys("Alt", "A"),
          "dpad:up": keys("Ctrl", "Tab"), "dpad:right": keys("Alt", "Z"),
          "dpad:down": keys("Alt", "G"), "dpad:left": keys("Alt", "U")}
    return {1: s1, 2: s2, 3: s3, 4: s4}


# ---- XML helpers ----------------------------------------------------------------------

def text(parent, tag, value):
    ET.SubElement(parent, tag).text = str(value)


def slot(parent_slots, kind, value):
    el = ET.SubElement(parent_slots, "slot")
    if kind == "key":
        text(el, "code", f"0x{KEYS[value]:x}")
        text(el, "mode", "keyboard")
    elif kind == "mouse":
        text(el, "code", value)
        text(el, "mode", "mousebutton")
    elif kind == "move":
        text(el, "code", MOVE[value])
        text(el, "mode", "mousemovement")
    else:  # pragma: no cover
        raise ValueError(kind)


def button_el(parent, tag, index, slots=(), setchange=None, pointer=False):
    el = ET.SubElement(parent, tag, index=str(index))
    if pointer:
        text(el, "mousespeedx", LEFT_STICK_SPEED)
        text(el, "mousespeedy", LEFT_STICK_SPEED)
        text(el, "mouseacceleration", "precision")
    if setchange:
        text(el, "setselect", setchange)
        text(el, "setselectcondition", "while-held")
    if slots:
        sl = ET.SubElement(el, "slots")
        for kind, value in slots:
            slot(sl, kind, value)
    return el


def build_set(num, entries):
    st = ET.Element("set", index=str(num))
    changes = SET_CHANGE[num]

    # left stick: relative mouse, Enhanced Precision curve, ~15% dead zone
    left = ET.SubElement(st, "stick", index="1")
    text(left, "deadZone", STICK_DEADZONE)
    for d, idx in STICK_DIR.items():
        button_el(left, "stickbutton", idx, [("move", d)], pointer=True)

    # right stick: wheel up/down only (zoom); left/right unbound
    right = ET.SubElement(st, "stick", index="2")
    button_el(right, "stickbutton", STICK_DIR["up"], [("mouse", WHEEL_UP)])
    button_el(right, "stickbutton", STICK_DIR["down"], [("mouse", WHEEL_DOWN)])

    dpad = ET.SubElement(st, "dpad", index="1")
    for d, idx in DPAD.items():
        if f"dpad:{d}" in entries:
            button_el(dpad, "dpadbutton", idx, entries[f"dpad:{d}"])

    for name, idx in TRIGGER.items():
        slots = entries.get(name, [])
        sc = changes.get(name)
        if slots or sc:
            tr = ET.SubElement(st, "trigger", index=str(idx))
            text(tr, "throttle", "positivehalf")
            button_el(tr, "triggerbutton", 2, slots, setchange=sc)

    for name, idx in sorted(BUTTON_INDEX.items(), key=lambda kv: kv[1]):
        slots = entries.get(name, [])
        sc = changes.get(name)
        # a set-change button carries no hotkey of its own in the set that owns the change
        if sc:
            slots = []
        if slots or sc:
            button_el(st, "button", idx, slots, setchange=sc)
    return st


def build():
    root = ET.Element("gamecontroller", configversion=CONFIG_VERSION, appversion=APP_VERSION)
    text(root, "sdlname", "Xbox 360 Controller")
    sets = ET.SubElement(root, "sets")
    for num, entries in build_sets().items():
        sets.append(build_set(num, entries))
    ET.indent(root, space="  ")
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding="unicode") + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate the AntiMicroX profile for Ragnarok.")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--check", action="store_true", help="exit 1 if --out differs from the generated profile")
    args = ap.parse_args(argv)
    out = args.out or HERE / "ragnarok.amgp"
    data = build()
    if args.check:
        if out.exists() and out.read_text(encoding="utf-8") == data:
            print(f"ok      {out}")
            return 0
        print(f"stale   {out}: regenerate with build_profile.py", file=sys.stderr)
        return 1
    out.write_text(data, encoding="utf-8")
    print(f"wrote   {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
