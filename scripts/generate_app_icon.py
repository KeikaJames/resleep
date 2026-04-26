#!/usr/bin/env python3
"""Generate placeholder App Icon assets for iOS and watchOS targets.

Style: deep navy background, soft white crescent moon. One shape, one
gradient-free fill, slight inner shadow on the crescent — matches Apple's
calm-restraint icon style (Health, Sleep, Reminders).

Run:
    python3 scripts/generate_app_icon.py

Outputs:
    apple/SleepTracker-iOS/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
    apple/SleepTracker-Watch/Resources/Assets.xcassets/AppIcon.appiconset/icon-<size>.png  (full Watch matrix)
    Contents.json for both appiconsets
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

REPO = Path(__file__).resolve().parents[1]
IOS_ICONSET = REPO / "apple/SleepTracker-iOS/Resources/Assets.xcassets/AppIcon.appiconset"
WATCH_ICONSET = REPO / "apple/SleepTracker-Watch/Resources/Assets.xcassets/AppIcon.appiconset"

# Brand palette: deep navy night sky, soft warm white moon.
BG_TOP = (24, 38, 72)        # #182648 — top of background (subtle blue lift)
BG_BOTTOM = (8, 14, 32)      # #080E20 — bottom (vignette)
MOON = (245, 244, 240)       # #F5F4F0 — soft warm white


def render_master(size: int = 1024) -> Image.Image:
    # Vertical gradient background.
    grad = Image.new("RGB", (1, size))
    px = grad.load()
    for y in range(size):
        t = y / (size - 1)
        r = int(BG_TOP[0] * (1 - t) + BG_BOTTOM[0] * t)
        g = int(BG_TOP[1] * (1 - t) + BG_BOTTOM[1] * t)
        b = int(BG_TOP[2] * (1 - t) + BG_BOTTOM[2] * t)
        px[0, y] = (r, g, b)
    bg = grad.resize((size, size), Image.BILINEAR).convert("RGBA")

    # Crescent moon: full disk, then subtract an offset disk via alpha math.
    full = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fd = ImageDraw.Draw(full)
    cx, cy = size * 0.50, size * 0.48
    r = size * 0.30
    fd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=MOON + (255,))

    cut = Image.new("L", (size, size), 0)
    cd = ImageDraw.Draw(cut)
    ox, oy = cx + r * 0.42, cy - r * 0.10
    cr = r * 0.95
    cd.ellipse((ox - cr, oy - cr, ox + cr, oy + cr), fill=255)

    fr, fg, fb, fa = full.split()
    new_a = ImageChops.subtract(fa, cut)
    moon = Image.merge("RGBA", (fr, fg, fb, new_a))

    # Tiny accent star bottom-right, very subtle.
    star = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(star)
    sx, sy, sr = size * 0.74, size * 0.72, size * 0.012
    sd.ellipse((sx - sr, sy - sr, sx + sr, sy + sr), fill=MOON + (160,))

    bg.alpha_composite(moon)
    bg.alpha_composite(star)
    return bg.convert("RGB")


def write_ios_iconset(master: Image.Image) -> None:
    IOS_ICONSET.mkdir(parents=True, exist_ok=True)
    out = IOS_ICONSET / "icon-1024.png"
    master.save(out, format="PNG", optimize=True)
    contents = {
        "images": [
            {
                "filename": "icon-1024.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (IOS_ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2))


# Watch sizes: (filename_size_pt, scale, idiom, role, subtype) needed by Apple Watch Ultra 49mm/45mm/41mm/40mm.
# Modern (watchOS 10+) accepts a single 1024×1024 universal entry per appiconset, same
# as iOS 17+. Use that to keep the bundle small and the script trivial.
def write_watch_iconset(master: Image.Image) -> None:
    WATCH_ICONSET.mkdir(parents=True, exist_ok=True)
    out = WATCH_ICONSET / "icon-1024.png"
    master.save(out, format="PNG", optimize=True)
    contents = {
        "images": [
            {
                "filename": "icon-1024.png",
                "idiom": "universal",
                "platform": "watchos",
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (WATCH_ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2))


def main() -> None:
    master = render_master(1024)
    write_ios_iconset(master)
    write_watch_iconset(master)
    print(f"Wrote AppIcon to {IOS_ICONSET}")
    print(f"Wrote AppIcon to {WATCH_ICONSET}")


if __name__ == "__main__":
    main()
