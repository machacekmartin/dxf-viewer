#!/usr/bin/env python3
"""Compose the README hero image: background + icon + wordmark."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from pathlib import Path

HERE = Path(__file__).parent
BG   = HERE / "background.png"
ICON = HERE / "icon.png"
OUT  = HERE / "hero.png"

# Final hero canvas — 2:1 banner, retina-friendly
W, H = 2400, 1200

bg = Image.open(BG).convert("RGB")
# Cover-fit the background onto the canvas
ar_canvas = W / H
ar_bg = bg.width / bg.height
if ar_bg > ar_canvas:
    new_h = H
    new_w = int(H * ar_bg)
else:
    new_w = W
    new_h = int(W / ar_bg)
bg = bg.resize((new_w, new_h), Image.LANCZOS)
left = (new_w - W) // 2
top  = (new_h - H) // 2
bg = bg.crop((left, top, left + W, top + H))

canvas = bg.copy()

# Gentle vertical darkening at top + bottom for text legibility
overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)
for y in range(H):
    # Darken stronger near top/bottom, leave middle alone
    t = abs((y / H) - 0.5) * 2.0           # 0 at middle → 1 at edges
    a = int(min(120, 70 * t ** 1.6))
    draw.line([(0, y), (W, y)], fill=(0, 0, 0, a))
canvas = Image.alpha_composite(canvas.convert("RGBA"), overlay).convert("RGB")

# --- Icon ---
icon = Image.open(ICON).convert("RGBA")
ICON_SIZE = 320
icon = icon.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)

# Drop shadow
shadow = Image.new("RGBA", (ICON_SIZE + 200, ICON_SIZE + 200), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle(
    (100, 100, 100 + ICON_SIZE, 100 + ICON_SIZE),
    radius=int(ICON_SIZE * 0.22),
    fill=(0, 0, 0, 200),
)
shadow = shadow.filter(ImageFilter.GaussianBlur(38))

ICON_Y = 280
ICON_X = (W - ICON_SIZE) // 2
canvas_rgba = canvas.convert("RGBA")
canvas_rgba.alpha_composite(shadow, (ICON_X - 100, ICON_Y - 60))
canvas_rgba.alpha_composite(icon, (ICON_X, ICON_Y))
canvas = canvas_rgba.convert("RGB")

# --- Type ---
def load_font(size, weight=400, optical=28):
    """Load SF Pro (system) with explicit variation axes.

    SFNS.ttf axis order: Width, Optical Size, GRAD, Weight.
    """
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size=size)
        # Width=100 (normal), Optical Size=optical, GRAD=0, Weight=weight
        f.set_variation_by_axes([100, optical, 0, weight])
        return f
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size=size)

draw = ImageDraw.Draw(canvas)

# Wordmark "DXF Viewer" — SF Pro Display, Bold (700), large optical size
title_font = load_font(180, weight=700, optical=96)
title = "DXF Viewer"
tw = draw.textlength(title, font=title_font)
TITLE_Y = ICON_Y + ICON_SIZE + 60
draw.text(
    ((W - tw) / 2, TITLE_Y),
    title,
    font=title_font,
    fill=(248, 248, 252),
)

# Tagline — SF Pro Text, regular (400), text optical size
sub_font = load_font(52, weight=420, optical=28)
sub = "Native macOS reader for AutoCAD DXF drawings"
sw = draw.textlength(sub, font=sub_font)
SUB_Y = TITLE_Y + 220
draw.text(
    ((W - sw) / 2, SUB_Y),
    sub,
    font=sub_font,
    fill=(220, 220, 232),
)

canvas.save(OUT, "PNG", optimize=True)
print(f"wrote {OUT} ({W}x{H})")
