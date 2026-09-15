#!/usr/bin/env python3
"""The day file of the owner's "Thank You" table picture: the same Lottie in a deeper gold.

    python3 tools/tables/make_thank_you_day.py <Thank You.json> [--out "Thank You Day.json"] [--gold 8A6A18]

The owner's upload draws the words and 35 sparkling shapes in #FCC700, a gold
that reads on the dark theme's ground and all but vanishes on the light one
(owner, 16 Sep 2026: "Thank You text not visible in Day mode"). The day file
is that file with every fill — the 140 shape fills and the text layer's own
fill — set to the light theme's gold, AppTheme.goldDeep (#8A6A18), the colour
the lobby's boot figures already wear by day. Nothing else changes: the
animation is 7,722 per-frame keyframes of a twinkle nobody can re-sample
without changing it, so unlike Background Pattern this file is not re-encoded,
and at 728 KB it cannot travel through a Drive upload from a session here — the
owner uploads it (~/Downloads is where it is written) and the seed row takes
the two URLs, night_asset_url the original.

The result is checked: loaded back, it must equal the source in every value
but the fills, and the number of fills changed must be the number found.
Python 3, standard library only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

NIGHT_GOLD = (0.992, 0.776, 0.0)  # #FCC700 as the file writes it, to 3 places
TOLERANCE = 0.02


def hex_to_unit(hex_colour: str) -> list[float]:
    h = hex_colour.lstrip("#")
    return [round(int(h[i:i + 2], 16) / 255, 3) for i in (0, 2, 4)]


def is_night_gold(rgb) -> bool:
    return len(rgb) >= 3 and all(abs(a - b) <= TOLERANCE for a, b in zip(rgb[:3], NIGHT_GOLD))


def recolour(node, gold, found):
    """Every still fill colour (`fl.c`) and text fill (`fc`) that is the night gold becomes `gold`."""
    if isinstance(node, dict):
        if node.get("ty") == "fl" and isinstance(node.get("c"), dict) and node["c"].get("a") == 0:
            k = node["c"]["k"]
            if is_night_gold(k):
                node["c"]["k"] = gold + k[3:]
                found["fills"] += 1
            else:
                found["other"].append(k)
        if "fc" in node and isinstance(node["fc"], list) and is_night_gold(node["fc"]):
            node["fc"] = gold + node["fc"][3:]
            found["text"] += 1
        if node.get("ty") == "fl" and node.get("c", {}).get("a") == 1:
            sys.exit("an animated fill colour: not expected in this file")
        for value in node.values():
            recolour(value, gold, found)
    elif isinstance(node, list):
        for value in node:
            recolour(value, gold, found)


def is_scalar_list(value) -> bool:
    return isinstance(value, list) and all(not isinstance(v, (dict, list)) for v in value)


def differences(a, b, path="", out=None):
    """The paths at which two JSON trees differ (values compared exactly; a list of numbers is one value)."""
    if out is None:
        out = []
    if isinstance(a, dict) and isinstance(b, dict):
        for key in set(a) | set(b):
            if key not in a or key not in b:
                out.append(path + "/" + str(key))
            else:
                differences(a[key], b[key], path + "/" + str(key), out)
    elif isinstance(a, list) and isinstance(b, list) and not (is_scalar_list(a) and is_scalar_list(b)):
        if len(a) != len(b):
            out.append(path + "/len")
        for i, (x, y) in enumerate(zip(a, b)):
            differences(x, y, f"{path}[{i}]", out)
    elif a != b:
        out.append(path)
    return out


def main():
    ap = argparse.ArgumentParser(description="Recolour the Thank You Lottie for the light theme.")
    ap.add_argument("source", help="the owner's Thank You.json")
    ap.add_argument("--out", default=str(Path.home() / "Downloads" / "Thank You Day.json"))
    ap.add_argument("--gold", default="8A6A18", help="the day gold, hex (default AppTheme.goldDeep)")
    args = ap.parse_args()

    source = json.loads(Path(args.source).read_text())
    day = json.loads(json.dumps(source))
    gold = hex_to_unit(args.gold)
    found = {"fills": 0, "text": 0, "other": []}
    recolour(day, gold, found)
    if found["other"]:
        sys.exit(f"fills in other colours, not touched: {found['other'][:3]} — look before shipping")

    changed = differences(source, day)
    fill_paths = [p for p in changed if p.endswith("/c/k") or p.endswith("/fc")]
    if len(changed) != len(fill_paths) or len(fill_paths) != found["fills"] + found["text"]:
        sys.exit(f"the day file differs from the source in {len(changed)} places, {len(fill_paths)} of them fills")

    out = Path(args.out)
    out.write_text(json.dumps(day, separators=(",", ":")))
    print(f"{out}: {out.stat().st_size:,} bytes; {found['fills']} shape fills and {found['text']} text fill(s) "
          f"#{args.gold.upper()} in place of #FCC700; nothing else differs from the source")


if __name__ == "__main__":
    main()
