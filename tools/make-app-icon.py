#!/usr/bin/env python3
"""Draw the iOS app icon.

    python3 tools/make-app-icon.py

The upstream macOS app ships an Icon Composer document (`.icon`), which is a
macOS-only format: `actool` on iOS cannot read it, and an app with no icon is
an app with no icon. So the icon is drawn here instead.

The design keeps the upstream's idea -- an aperture, which is what a lens does
and therefore what a simulator of one does -- and drops the part that cannot
survive the trip: the macOS icon is a translucent, shadowed rounded square,
and an iOS icon is an opaque square that the system masks. So this is a flat
opaque square with the aperture in it, and the system does the rest.

The sizes are the ones `AppIcon.appiconset` asks for, at 1x, 2x and 3x.
"""

from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageDraw, ImageFilter
except ImportError:
    print("Pillow is needed: pip install Pillow", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parents[1]
# NOTE: the catalog must live *beside* `Resources/`, not inside it. `gen-project.py`
# carries `Resources` as a folder reference (copied verbatim into the bundle), and
# an `.xcassets` nested inside a folder reference is never compiled by `actool` --
# so the icon would silently never register. At this path `gen-project.py` picks it
# up as a `folder.assetcatalog` and Xcode compiles it normally.
OUT = ROOT / "ios" / "SpektraLab" / "Assets.xcassets" / "AppIcon.appiconset"

# The palette: a near-black ground, a warm red for the aperture blades, and a
# thin warm ring for the lens barrel. It reads at 60 pt on a home screen and
# at 180 pt on a settings screen.
GROUND_TOP = (18, 16, 16)
GROUND_BOTTOM = (8, 7, 7)
BLADE = (214, 58, 46)
BLADE_DARK = (150, 33, 26)
RING = (232, 206, 168)
CORE = (250, 246, 238)

BASE = 1024


def draw_icon(size: int) -> Image.Image:
    """The icon at `size` pixels square."""
    s = size / BASE
    img = Image.new("RGB", (size, size), GROUND_BOTTOM)
    draw = ImageDraw.Draw(img)

    # The ground: a soft vertical gradient, so the icon has a direction even
    # before the aperture is drawn.
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(GROUND_TOP[0] + (GROUND_BOTTOM[0] - GROUND_TOP[0]) * t)
        g = int(GROUND_TOP[1] + (GROUND_BOTTOM[1] - GROUND_TOP[1]) * t)
        b = int(GROUND_TOP[2] + (GROUND_BOTTOM[2] - GROUND_TOP[2]) * t)
        draw.line([(0, y), (size, y)], fill=(r, g, b))

    cx = cy = size / 2
    outer = size * 0.40
    inner = size * 0.155

    # The lens barrel: a thin warm ring.
    ring_w = max(1, int(size * 0.018))
    draw.ellipse([cx - outer, cy - outer, cx + outer, cy + outer],
                 outline=RING, width=ring_w)

    # The iris: six blades that overlap into a hexagonal opening.
    #
    # A real iris is not a star. Each blade is a shape whose straight edge
    # cuts across the barrel, and where six of them overlap they leave a
    # hexagon in the middle. That is what is drawn here: a ring of six
    # blades, each one a large disc clipped by the barrel, with the hexagon
    # left open in the centre.
    #
    # The trick is to draw the blades as a union of six circles offset
    # outwards, and then cut the opening out of the union. The opening is a
    # hexagon, because six blades meeting at six points make six sides.
    blades = 6
    # The iris.
    #
    # Six annular sectors, each spanning 60 degrees of the ring between the
    # barrel's inner circle and the opening's circle, drawn alternately in two
    # tones. The opening in the middle is a regular hexagon, because six
    # blades meeting at six points make six sides -- so the hexagon's
    # inradius is the opening's radius, and the sectors are clipped by it.
    inner = outer * 0.30

    # The opening: a regular hexagon.
    hex_pts = []
    for i in range(6):
        angle = math.pi / 6 + (i / 6) * 2 * math.pi
        hex_pts.append((cx + inner * math.cos(angle) / math.cos(math.pi / 6),
                        cy + inner * math.sin(angle) / math.cos(math.pi / 6)))
    hole = Image.new("L", (size, size), 0)
    ImageDraw.Draw(hole).polygon(hex_pts, fill=255)

    # The barrel's inner circle: the sectors are drawn between this and the
    # outer rim.
    barrel_r = outer * 0.90

    for i in range(blades):
        start = math.pi / 6 + (i / blades) * 2 * math.pi
        end = start + (2 * math.pi / blades)
        tone = BLADE if i % 2 == 0 else BLADE_DARK
        sector = Image.new("L", (size, size), 0)
        sd = ImageDraw.Draw(sector)
        # An annular sector, drawn as a polygon: the outer arc out, the inner
        # arc back, with enough steps that the curve looks like a curve.
        steps = 96
        pts = []
        for k in range(steps + 1):
            a = start + (end - start) * k / steps
            pts.append((cx + barrel_r * math.cos(a), cy + barrel_r * math.sin(a)))
        for k in range(steps, -1, -1):
            a = start + (end - start) * k / steps
            pts.append((cx + inner * math.cos(a), cy + inner * math.sin(a)))
        sd.polygon(pts, fill=255)
        # The opening is cut out of every sector: it is the light coming
        # through, not a blade.
        sector = ImageChops.subtract(sector, hole)
        img.paste(Image.new("RGB", (size, size), tone), (0, 0), sector)

    # The opening itself: the light that got through.
    img.paste(Image.new("RGB", (size, size), CORE), (0, 0), hole)

    # The barrel ring, drawn over the blades' outer edge so the lens has a
    # rim rather than a cut-off disc.
    draw.ellipse([cx - outer, cy - outer, cx + outer, cy + outer],
                 outline=RING, width=ring_w)

    # A small highlight on the opening's edge, so the centre reads as glass
    # rather than as a hole. It is blurred, then added: a screen blend would
    # wash the ground out, and an alpha blend would need a mask.
    hl = Image.new("RGB", (size, size), (0, 0, 0))
    hld = ImageDraw.Draw(hl)
    hld.ellipse([cx - inner * 0.86, cy - inner * 0.96, cx + inner * 0.18, cy - inner * 0.10],
                fill=(96, 90, 80))
    hl = hl.filter(ImageFilter.GaussianBlur(size * 0.014))
    px = img.load()
    hp = hl.load()
    for y in range(size):
        for x in range(size):
            r, g, b = px[x, y]
            hr, hg, hb = hp[x, y]
            px[x, y] = (min(255, r + hr), min(255, g + hg), min(255, b + hb))

    return img


SIZES = {
    "icon-20@2x.png": 40,
    "icon-20@3x.png": 60,
    "icon-29@2x.png": 58,
    "icon-29@3x.png": 87,
    "icon-40@2x.png": 80,
    "icon-40@3x.png": 120,
    "icon-60@2x.png": 120,
    "icon-60@3x.png": 180,
    "icon-1024.png": 1024,
    "icon-76@1x.png": 76,
    "icon-76@2x.png": 152,
    "icon-83.5@2x.png": 167,
}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    # `actool` requires the catalog's own `Contents.json`, not just the
    # `AppIcon.appiconset` one. Without it the catalog fails to compile and the
    # icon never registers.
    catalog = OUT.parent
    (catalog / "Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")
    for name, size in SIZES.items():
        img = draw_icon(size)
        img.save(OUT / name, "PNG")
        print(f"  {name} ({size}x{size})")

    # The `Contents.json` that tells `actool` which file is which.
    images = []
    for name, size in SIZES.items():
        if name == "icon-1024.png":
            idiom, scale = "ios-marketing", "1x"
        else:
            base, _, sx = name[:-4].rpartition("@")
            idiom = base.replace("icon-", "")
            scale = sx
        images.append({
            "filename": name,
            "idiom": idiom,
            "scale": scale,
            "size": f"{size}x{size}",
        })
    # `actool` wants the marketing icon last and the others in a stable order.
    images.sort(key=lambda e: (e["idiom"] != "ios-marketing", e["idiom"], e["scale"]))
    (OUT / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
