#!/usr/bin/env python3
"""Draws the table pictures the server seeds (V1.0.3__seed_table_pictures.sql).

One SVG per picture per mode, written into go-server/public/tables/. Every
picture is a pair: the DAY file is a pale cloth for the light theme, whose ink
on the table is dark, and the NIGHT file a deep one for the dark theme, whose
ink is light — the reason table_pictures carries two URLs at all (the DDL's
header). The two are the same design in two palettes, so a player who flips
the theme keeps the table they chose.

Plain SVG on purpose: gradients, strokes and paths only. flutter_svg draws no
<filter> and the app's icon already logs "unhandled element <filter/>", and a
<pattern> is avoided for the same caution, so a weave is drawn as the lines it
is. The canvas is 1600×900 and the app draws it with BoxFit.cover, so the edge
ornaments sit well inside the frame and survive a crop on any phone.

    python3 tools/tables/make_table_pictures.py        # rewrites the 16 files

Standard library only, like tools/lottie/*.py.
"""
from __future__ import annotations

import math
import os
from dataclasses import dataclass

W, H = 1600, 900
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "go-server", "public", "tables")


@dataclass(frozen=True)
class Palette:
    core: str   # the lit middle of the cloth
    mid: str
    rim: str    # the edge, where the lamp does not reach
    line: str   # the border and any ornament
    line_alpha: float
    ornament_alpha: float


@dataclass(frozen=True)
class Design:
    slug: str
    day: Palette
    night: Palette
    motif: str  # one of the drawers below


def cloth(p: Palette) -> str:
    """The cloth itself: lit a little above the middle, darker at the rim."""
    return f"""  <defs>
    <radialGradient id="cloth" cx="50%" cy="42%" r="78%">
      <stop offset="0" stop-color="{p.core}"/>
      <stop offset="0.55" stop-color="{p.mid}"/>
      <stop offset="1" stop-color="{p.rim}"/>
    </radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.10"/>
      <stop offset="0.35" stop-color="#ffffff" stop-opacity="0.03"/>
      <stop offset="0.7" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect width="{W}" height="{H}" fill="url(#cloth)"/>
  <rect width="{W}" height="{H}" fill="url(#sheen)"/>
"""


def border(p: Palette, inset: int = 46, gap: int = 14) -> str:
    """A double hairline round the cloth, the rail's shadow on it."""
    a = p.line_alpha
    return (
        f'  <rect x="{inset}" y="{inset}" width="{W - 2 * inset}" height="{H - 2 * inset}" rx="40" '
        f'fill="none" stroke="{p.line}" stroke-opacity="{a:.2f}" stroke-width="3"/>\n'
        f'  <rect x="{inset + gap}" y="{inset + gap}" width="{W - 2 * (inset + gap)}" '
        f'height="{H - 2 * (inset + gap)}" rx="30" fill="none" stroke="{p.line}" '
        f'stroke-opacity="{a * 0.5:.2f}" stroke-width="1.5"/>\n'
    )


def motif_plain(p: Palette) -> str:
    return ""


def motif_corner_diamonds(p: Palette) -> str:
    """A small diamond in each corner, between the two border lines."""
    out = []
    for cx, cy in [(46 + 7, 46 + 7), (W - 53, 53), (53, H - 53), (W - 53, H - 53)]:
        out.append(
            f'  <path d="M{cx} {cy - 22} L{cx + 22} {cy} L{cx} {cy + 22} L{cx - 22} {cy} Z" '
            f'fill="{p.line}" fill-opacity="{p.ornament_alpha:.2f}"/>\n'
        )
    return "".join(out)


def motif_deco_rays(p: Palette) -> str:
    """Art-deco rays fanning from the two lower corners, faint."""
    out = []
    for ox, sign in [(0, 1), (W, -1)]:
        for i in range(9):
            angle = math.radians(12 + i * 8)
            x = ox + sign * math.cos(angle) * 720
            y = H - math.sin(angle) * 720
            out.append(
                f'  <line x1="{ox}" y1="{H}" x2="{x:.0f}" y2="{y:.0f}" stroke="{p.line}" '
                f'stroke-opacity="{p.ornament_alpha * (0.35 + 0.65 * (1 - i / 9)):.3f}" stroke-width="2"/>\n'
            )
    return "".join(out)


def motif_lattice(p: Palette) -> str:
    """Diagonal lines both ways: a diamond lattice over the cloth."""
    out = []
    step = 96
    for k in range(-H, W + H, step):
        out.append(
            f'  <line x1="{k}" y1="0" x2="{k + H}" y2="{H}" stroke="{p.line}" '
            f'stroke-opacity="{p.ornament_alpha:.3f}" stroke-width="1.2"/>\n'
        )
        out.append(
            f'  <line x1="{k}" y1="{H}" x2="{k + H}" y2="0" stroke="{p.line}" '
            f'stroke-opacity="{p.ornament_alpha:.3f}" stroke-width="1.2"/>\n'
        )
    return "".join(out)


def motif_weave(p: Palette) -> str:
    """A tight diagonal weave, one direction lit and the other shadowed."""
    out = []
    step = 22
    for k in range(-H, W + H, step):
        out.append(
            f'  <line x1="{k}" y1="0" x2="{k + H}" y2="{H}" stroke="#ffffff" '
            f'stroke-opacity="{p.ornament_alpha:.3f}" stroke-width="1"/>\n'
        )
        out.append(
            f'  <line x1="{k + step // 2}" y1="{H}" x2="{k + step // 2 + H}" y2="0" stroke="#000000" '
            f'stroke-opacity="{p.ornament_alpha * 0.8:.3f}" stroke-width="1"/>\n'
        )
    return "".join(out)


def motif_marble(p: Palette) -> str:
    """Veins: a few long soft curves, as marble is."""
    out = []
    veins = [
        "M-40 220 C 300 160, 520 380, 900 300 S 1400 120, 1700 260",
        "M-40 640 C 260 700, 480 520, 820 600 S 1300 760, 1700 620",
        "M200 -40 C 260 200, 120 420, 260 640 S 420 860, 380 960",
        "M1240 -40 C 1180 180, 1340 380, 1220 600 S 1100 820, 1180 960",
        "M-40 430 C 400 470, 700 400, 1000 470 S 1500 420, 1700 470",
    ]
    for i, d in enumerate(veins):
        out.append(
            f'  <path d="{d}" fill="none" stroke="{p.line}" '
            f'stroke-opacity="{p.ornament_alpha * (0.6 + 0.4 * (i % 2)):.3f}" stroke-width="{2.5 if i % 2 else 1.5}"/>\n'
        )
    return "".join(out)


def motif_flourish(p: Palette) -> str:
    """A curled flourish in each corner, in the border's colour."""
    out = []
    a = p.ornament_alpha
    for sx, sy in [(1, 1), (-1, 1), (1, -1), (-1, -1)]:
        ox = 90 if sx > 0 else W - 90
        oy = 90 if sy > 0 else H - 90
        # Two arcs and a stem, mirrored into each corner.
        d = (
            f"M{ox} {oy + sy * 120} "
            f"Q{ox} {oy} {ox + sx * 120} {oy} "
            f"M{ox + sx * 24} {oy + sy * 24} "
            f"Q{ox + sx * 24} {oy + sy * 96} {ox + sx * 96} {oy + sy * 96} "
            f"Q{ox + sx * 60} {oy + sy * 84} {ox + sx * 48} {oy + sy * 48}"
        )
        out.append(
            f'  <path d="{d}" fill="none" stroke="{p.line}" stroke-opacity="{a:.2f}" '
            f'stroke-width="3" stroke-linecap="round"/>\n'
        )
        out.append(
            f'  <circle cx="{ox + sx * 48}" cy="{oy + sy * 48}" r="6" fill="{p.line}" fill-opacity="{a:.2f}"/>\n'
        )
    return "".join(out)


MOTIFS = {
    "plain": motif_plain,
    "corner_diamonds": motif_corner_diamonds,
    "deco_rays": motif_deco_rays,
    "lattice": motif_lattice,
    "weave": motif_weave,
    "marble": motif_marble,
    "flourish": motif_flourish,
}

GOLD = "#D4AF37"
SILVER = "#C9CDD4"

DESIGNS = [
    Design(
        "classic-baize",
        day=Palette("#CFE6D6", "#B3D2BD", "#8FB59C", GOLD, 0.55, 0.30),
        night=Palette("#1E5A3A", "#144228", "#0A2416", GOLD, 0.55, 0.30),
        motif="plain",
    ),
    Design(
        "oxblood-club",
        day=Palette("#EBD6DB", "#D9B9C1", "#BC959F", GOLD, 0.55, 0.30),
        night=Palette("#4A2430", "#331821", "#190D11", GOLD, 0.55, 0.30),
        motif="plain",
    ),
    Design(
        "royal-sapphire",
        day=Palette("#D6DFF5", "#B9C8EC", "#93A7D6", SILVER, 0.70, 0.55),
        night=Palette("#1C2F66", "#132049", "#080F28", SILVER, 0.60, 0.55),
        motif="corner_diamonds",
    ),
    Design(
        "midnight-gold",
        day=Palette("#E6E4DF", "#D3D0C8", "#B5B1A7", GOLD, 0.70, 0.22),
        night=Palette("#24242C", "#16161B", "#08080A", GOLD, 0.70, 0.22),
        motif="deco_rays",
    ),
    Design(
        "sunset-marble",
        day=Palette("#F2E6D8", "#E6D2BC", "#CDB093", "#B98C5E", 0.50, 0.28),
        night=Palette("#4A3A30", "#362A22", "#1E1612", "#B98C5E", 0.50, 0.28),
        motif="marble",
    ),
    Design(
        "emerald-lattice",
        day=Palette("#D2ECDF", "#B2DBC7", "#86BCA2", "#2F7A56", 0.55, 0.16),
        night=Palette("#155C3E", "#0E4530", "#06281B", "#7FD3A8", 0.55, 0.16),
        motif="lattice",
    ),
    Design(
        "carbon-weave",
        day=Palette("#DEDFE3", "#CBCDD3", "#ADB0B8", "#6C7079", 0.55, 0.16),
        night=Palette("#2A2C31", "#1B1D21", "#0C0D0F", "#8A8E96", 0.55, 0.16),
        motif="weave",
    ),
    Design(
        "royal-purple",
        day=Palette("#E5D9F2", "#D2BFE8", "#B197D2", GOLD, 0.65, 0.55),
        night=Palette("#3A1F63", "#281445", "#120825", GOLD, 0.65, 0.55),
        motif="flourish",
    ),
]


def render(design: Design, mode: str) -> str:
    p = design.day if mode == "day" else design.night
    body = cloth(p) + MOTIFS[design.motif](p) + border(p)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">\n'
        f"  <!-- {design.slug}, {mode}: generated by tools/tables/make_table_pictures.py -->\n"
        f"{body}</svg>\n"
    )


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for design in DESIGNS:
        for mode in ("day", "night"):
            path = os.path.join(OUT, f"{design.slug}-{mode}.svg")
            with open(path, "w", encoding="utf-8") as f:
                f.write(render(design, mode))
            print(f"wrote {os.path.relpath(path)}")


if __name__ == "__main__":
    main()
