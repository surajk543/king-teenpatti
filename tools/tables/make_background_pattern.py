#!/usr/bin/env python3
"""Re-encode the owner's "Background Pattern" Lottie for the table-picture shelf.

    python3 tools/tables/make_background_pattern.py [--source tools/tables/background-pattern.json] [--out tools/tables]

writes <out>/background-pattern-day.json and <out>/background-pattern-night.json,
the two files the catalogue serves from Drive ("Background Pattern.json" and
"Background Pattern Night.json" in the owner's table_pictures folder).

THE SOURCE is the owner's Bodymovin export (v5.5.3, 25 fps, 150 frames,
1500x1000): 96 rounded 60x60 tiles in two blues, each its own shape layer with
its own copy of the same path and the same five scale keyframes — pop in from
nothing to 105% and settle at 100% over 27 frames, starting at that tile's own
frame, then every tile shrinks away together over frames 133-145 and the loop
starts over. 122 KB, most of it 96 copies of the same thing. A Drive upload from
a session here travels through a tool call, so the size is the whole reason for
this script.

THE ENCODING writes the pop-in ONCE per colour, as a precomp ("pale" and
"blue"), and makes each tile an instance of it: placed at the tile's centre,
started at the tile's own frame through `st`, which shifts a precomp's contents
and nothing else — the convention of every Bodymovin export (a shifted layer's
own keyframes stay in composition time: Fireworks.json, st 26, keyframes at
33..42) and of both players, lottie-web and lottie-android/flutter. The shared
shrink-out is the instance's own scale keyframes, in composition time, verbatim
from the source; a tile that also fades (layers 21-30) keeps its opacity
keyframes the same way. Two tiles (layers 55 and 64) bounce twice and keep all
their keyframes whole as flat shape layers. The path becomes the rectangle
shape it is (`rc`, radius 11.577); the precomp canvas is 70x70 so the 105%
overshoot is never clipped. ~29 KB each.

THE NIGHT FILE is the same encoding with the pale blue (#E3F2FD, a tint that
all but vanishes on the light theme's pale ground) swapped for a navy tint
(#1B2F42) that sits on the dark theme's ground the same way; the mid blue
(#64B5F6) reads on both grounds and stays.

Nothing is trusted: every source layer is checked to be the tile the precomp
draws (the path's eight corners and handles, the anchors, the group transform)
and every keyframe of a tile that becomes an instance must match the shared
pop-in and shrink-out — time, value and easing — shifted by its start frame;
a tile that does not stays a flat layer with its own keyframes. Python 3,
standard library only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

TILE = 60          # the tile's side
RADIUS = 11.577    # its corner radius: the path's straight run ends 18.423 from the centre
CANVAS = 70        # the precomp's canvas, with room for the 105% overshoot
CENTRE = CANVAS // 2
FRAMES = 150

DAY = {"pale": [0.889, 0.948, 0.991, 1], "blue": [0.391, 0.709, 0.964, 1]}
NIGHT = {"pale": [0.106, 0.184, 0.259, 1], "blue": [0.391, 0.709, 0.964, 1]}

# The shared curves, verbatim from the source (every tile's first, second and
# fourth keyframe carry exactly these easings).
EASE_IN = {"i": {"x": [0.667, 0.667, 0.667], "y": [1, 1, 1]},
           "o": {"x": [1, 1, 0.333], "y": [0.011, 0.011, 0]}}
EASE = {"i": {"x": [0.667, 0.667, 0.667], "y": [1, 1, 1]},
        "o": {"x": [0.333, 0.333, 0.333], "y": [0, 0, 0]}}
# Inside the precomp, from its own frame 0: nothing → 105% → 100%, then hold.
POP_IN = [dict(EASE_IN, t=0, s=[0, 0, 100]),
          dict(EASE, t=25, s=[105, 105, 100]),
          {"t": 27, "s": [100, 100, 100]}]
# On the instance, in composition time: 100% → nothing, for every tile at once.
SHRINK = [dict(EASE, t=133, s=[100, 100, 100]),
          {"t": 145, "s": [0, 0, 100]}]


def still(value):
    return {"a": 0, "k": value}


def near(a, b, tol=0.002):
    return abs(a - b) <= tol


def same(a, b):
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


def ease_of(keyframe):
    return {"i": keyframe["i"], "o": keyframe["o"]}


def colour_key(rgba):
    for key, want in DAY.items():
        if all(near(a, b, 1e-9) for a, b in zip(rgba, want)):
            return key
    sys.exit(f"a fill of {rgba} is neither of the pattern's two blues")


def check_tile_path(shape):
    """The source path must be the 60x60 rounded square the precomp draws."""
    path = shape["ks"]["k"]
    assert path["c"] and len(path["v"]) == 8, "a tile is an eight-point closed path"
    half, flat, handle = TILE / 2, TILE / 2 - RADIUS, 0.5523 * RADIUS
    for (x, y), tin, tout in zip(path["v"], path["i"], path["o"]):
        on_side = near(abs(x), half) and near(abs(y), flat)
        on_top = near(abs(x), flat) and near(abs(y), half)
        assert on_side or on_top, f"a corner at {x},{y} is not on the tile"
        for tangent in (tin, tout):
            live = [c for c in tangent if c]
            assert not live or (len(live) == 1 and near(abs(live[0]), handle)), f"a handle of {tangent}"


def check_layer(layer):
    """Every source layer is one tile: its centre at `p`, its pop keyed on `s`."""
    ks = layer["ks"]
    assert layer["ty"] == 4 and layer["st"] == 0 and layer["ip"] == 0 and layer["op"] == FRAMES
    assert layer.get("sr", 1) == 1 and "parent" not in layer and "tm" not in layer
    assert ks["r"] == still(0) and ks["a"] == still([30.25, 30.25, 0])
    assert ks["p"]["a"] == 0 and ks["p"]["k"][2] == 0
    assert ks["s"]["a"] == 1
    opacity = ks["o"]
    assert opacity == still(100) or (
        opacity["a"] == 1 and [k["t"] for k in opacity["k"]] == [133, 145]
        and opacity["k"][0]["s"] == [100] and opacity["k"][1]["s"] == [0]), "an opacity other than the shared fade"
    assert len(layer["shapes"]) == 1 and layer["shapes"][0]["ty"] == "gr"
    path, fill, transform = layer["shapes"][0]["it"]
    assert path["ty"] == "sh" and fill["ty"] == "fl" and transform["ty"] == "tr"
    assert fill["o"] == still(100) and fill["c"]["a"] == 0
    assert (transform["p"] == still([30.25, 30.25]) and transform["a"] == still([0, 0])
            and transform["s"] == still([100, 100]) and transform["r"] == still(0)
            and transform["o"] == still(100)), "a group transform other than the tile's"
    check_tile_path(path)


def pop_in_start(keyframes):
    """The frame this tile's keyframes start the shared pop-in at, or None if they are its own.

    The third keyframe's easing leads into a hold (100% → 100%), so it is not
    compared; the last is terminal.
    """
    if len(keyframes) != 5:
        return None
    t0 = keyframes[0]["t"]
    want = [(t0, [0, 0, 100], ease_of(POP_IN[0])),
            (t0 + 25, [105, 105, 100], ease_of(POP_IN[1])),
            (t0 + 27, [100, 100, 100], None),
            (133, [100, 100, 100], ease_of(SHRINK[0])),
            (145, [0, 0, 100], None)]
    for keyframe, (t, s, ease) in zip(keyframes, want):
        if keyframe["t"] != t or keyframe["s"] != s:
            return None
        if ease is not None and not same(ease_of(keyframe), ease):
            return None
    return t0


def rect():
    return {"ty": "rc", "d": 1, "s": still([TILE, TILE]), "p": still([0, 0]), "r": still(RADIUS)}


def fill(rgba):
    return {"ty": "fl", "c": still(rgba), "o": still(100), "r": 1}


def tile_comp(key, rgba):
    """One tile popping in at the precomp's own frame 0, centred on its canvas."""
    return {"id": key, "layers": [{
        "ind": 1, "ty": 4, "ip": 0, "op": FRAMES, "st": 0,
        "ks": {"o": still(100), "r": still(0), "p": still([CENTRE, CENTRE, 0]),
               "a": still([0, 0, 0]), "s": {"a": 1, "k": POP_IN}},
        "shapes": [rect(), fill(rgba)]}]}


def encode(source, palette):
    layers, own = [], []
    for layer in source["layers"]:
        check_layer(layer)
        _, source_fill, _ = layer["shapes"][0]["it"]
        key = colour_key(source_fill["c"]["k"])
        x, y, _ = layer["ks"]["p"]["k"]
        t0 = pop_in_start(layer["ks"]["s"]["k"])
        if t0 is None:
            # Its own bounce: the tile whole, keyframes verbatim, as a flat layer.
            own.append(layer["ind"])
            layers.append({
                "ind": layer["ind"], "ty": 4, "ip": 0, "op": FRAMES, "st": 0,
                "ks": {"o": layer["ks"]["o"], "r": still(0), "p": still([x, y, 0]),
                       "a": still([0, 0, 0]), "s": layer["ks"]["s"]},
                "shapes": [rect(), fill(palette[key])]})
            continue
        # A still opacity is the players' default and is left out (10 tiles fade).
        ks = {"p": still([x, y, 0]), "a": still([CENTRE, CENTRE, 0]), "s": {"a": 1, "k": SHRINK}}
        if layer["ks"]["o"]["a"] == 1:
            ks["o"] = layer["ks"]["o"]
        layers.append({
            "ind": layer["ind"], "ty": 0, "refId": key, "st": t0, "ip": t0, "op": FRAMES,
            "w": CANVAS, "h": CANVAS, "ks": ks})
    out = {"v": source["v"], "fr": source["fr"], "ip": source["ip"], "op": source["op"],
           "w": source["w"], "h": source["h"], "nm": "Background Pattern",
           "assets": [tile_comp(key, palette[key]) for key in ("pale", "blue")],
           "layers": layers, "markers": []}
    return out, own


def main():
    ap = argparse.ArgumentParser(description="Re-encode the Background Pattern Lottie, day and night.")
    ap.add_argument("--source", default=str(HERE / "background-pattern.json"), help="the owner's export")
    ap.add_argument("--out", default=str(HERE), help="where the two files go")
    args = ap.parse_args()
    source = json.loads(Path(args.source).read_text())
    assert (source["fr"], source["ip"], source["op"], source["w"], source["h"]) == (25, 0, FRAMES, 1500, 1000)
    assert len(source["layers"]) == 96 and not source.get("assets")
    for name, palette in (("day", DAY), ("night", NIGHT)):
        encoded, own = encode(source, palette)
        text = json.dumps(encoded, separators=(",", ":"))
        path = Path(args.out) / f"background-pattern-{name}.json"
        path.write_text(text)
        instances = sum(1 for layer in encoded["layers"] if layer["ty"] == 0)
        print(f"{path}: {len(text):,} bytes, {instances} instances of the two tiles, "
              f"{len(own)} tile(s) kept whole ({', '.join(map(str, own))})")


if __name__ == "__main__":
    main()
