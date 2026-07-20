#!/usr/bin/env python3
"""Rebuild assets/readme/drone-swarm.png — the README's "Meet the swarm" lineup.

Composites the full cast (Pulsar + every drone) from their master portraits
into colour-ringed rounded tiles with name + role labels. Run it after ANY
cast change (new drone, recoloured drone, new master art):

    python3 scripts/build-drone-swarm.py

Cast order/colours/roles mirror Sources/Models/DroneRegistry.swift — keep the
CAST table below in lockstep with the registry (colours are the locked drone
hues; roles are the registry roles, capitalised).
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent

# name, role, hex colour (DroneRegistry locked hues), master portrait path
CAST = [
    ("Pulsar",   "Orchestrator", "#818CF8", REPO / "assets/readme/pulsar.png"),
    ("Voyager",  "Explorer",     "#F2A83B", REPO / "design/drones/voyager.png"),
    ("Sentinel", "Reviewer",     "#6BB8EB", REPO / "design/drones/sentinel.png"),
    ("Nova",     "Builder",      "#5CD16B", REPO / "design/drones/nova.png"),
    ("Nebula",   "Artist",       "#E85CD1", REPO / "design/drones/nebula.png"),
    ("Echo",     "Writer",       "#2EBFB8", REPO / "design/drones/echo.png"),
    ("Iris",     "Marketer",     "#F26178", REPO / "design/drones/iris.png"),
    ("Atlas",    "Generalist",   "#8040C0", REPO / "design/drones/atlas.png"),
]

BG = (14, 14, 22)          # sampled from the original asset
ROLE_GREY = (120, 120, 145)
TILE = 190                  # portrait tile edge
RADIUS = 40                 # tile corner radius
BORDER = 3                  # ring width
CANVAS_H = 520
TILE_Y = 140                # tile top edge (vertical centre-ish, room for labels)
GAP_EDGE = 55               # first/last tile inset

OUT = REPO / "assets/readme/drone-swarm.png"


def font(size: int, bold: bool = False):
    for path, idx in [
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1 if bold else 0),
        ("/System/Library/Fonts/Helvetica.ttc", 1 if bold else 0),
    ]:
        try:
            return ImageFont.truetype(path, size, index=idx)
        except Exception:
            continue
    return ImageFont.load_default()


def rounded_tile(master: Path, hex_colour: str) -> Image.Image:
    """Master portrait resized into a rounded square with a coloured ring."""
    img = Image.open(master).convert("RGB").resize((TILE, TILE), Image.LANCZOS)
    tile = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    mask = Image.new("L", (TILE, TILE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, TILE - 1, TILE - 1], RADIUS, fill=255)
    tile.paste(img, (0, 0), mask)
    d = ImageDraw.Draw(tile)
    d.rounded_rectangle([1, 1, TILE - 2, TILE - 2], RADIUS, outline=hex_colour, width=BORDER)
    return tile


def main():
    n = len(CAST)
    gap = 34
    canvas_w = 2 * GAP_EDGE + n * TILE + (n - 1) * gap
    im = Image.new("RGB", (canvas_w, CANVAS_H), BG)
    draw = ImageDraw.Draw(im)
    name_f, role_f = font(30, bold=True), font(22)

    for i, (name, role, colour, master) in enumerate(CAST):
        x = GAP_EDGE + i * (TILE + gap)
        im.paste(rounded_tile(master, colour), (x, TILE_Y), rounded_tile(master, colour))
        cx = x + TILE // 2
        nw = draw.textlength(name, font=name_f)
        draw.text((cx - nw / 2, TILE_Y + TILE + 22), name, fill=colour, font=name_f)
        rw = draw.textlength(role, font=role_f)
        draw.text((cx - rw / 2, TILE_Y + TILE + 60), role, fill=ROLE_GREY, font=role_f)

    im.save(OUT)
    print(f"wrote {OUT} ({im.size[0]}x{im.size[1]}, {n} tiles)")


if __name__ == "__main__":
    main()
