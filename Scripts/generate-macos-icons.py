#!/usr/bin/env python3
"""Generate the SendHere macOS app-icon asset set."""
from pathlib import Path
from PIL import Image, ImageDraw

ASSET_DIR = Path(__file__).resolve().parents[1] / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
SIZES = (16, 32, 64, 128, 256, 512, 1024)
SCALE = 4
BLUE = "#2563EB"


def draw_rounded_line(draw, points, width, fill):
    draw.line(points, fill=fill, width=width, joint="curve")
    radius = width / 2
    for x, y in points:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def make_icon(size: int) -> Image.Image:
    canvas = size * SCALE
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # macOS app icons are expected to leave a margin inside the canvas: the
    # system draws them at a size that assumes the artwork does not run to the
    # edge. 0.075 reproduces the 85% squircle that ships in the asset set, so
    # the Dock and Launchpad render it at the same visual weight as other apps.
    inset = canvas * 0.075
    draw.rounded_rectangle(
        (inset, inset, canvas - inset, canvas - inset),
        radius=canvas * 0.185,
        fill=BLUE,
    )

    # A single horizontal transfer line with arrowheads at both ends.
    y = canvas * 0.50
    # Keep a clear gap between the two arrowheads: their inner corners must
    # not meet at the centre and look like a stacked/diamond glyph.
    left_tip, right_tip = canvas * 0.25, canvas * 0.75
    shaft_left, shaft_right = canvas * 0.36, canvas * 0.64
    # Longer vertical wings produce the open, prominent arrow angle from the
    # approved mark while leaving a clear, straight centre segment.
    wing = canvas * 0.10
    stroke = max(2, round(canvas * 0.065))
    white = "#FFFFFF"
    # Run the shaft through both tips so the mark reads as one continuous
    # bidirectional transfer line rather than three separated pieces.
    draw_rounded_line(draw, [(left_tip, y), (right_tip, y)], stroke, white)
    draw_rounded_line(draw, [(shaft_left, y - wing), (left_tip, y), (shaft_left, y + wing)], stroke, white)
    draw_rounded_line(draw, [(shaft_right, y - wing), (right_tip, y), (shaft_right, y + wing)], stroke, white)

    return image.resize((size, size), Image.Resampling.LANCZOS)


for size in SIZES:
    make_icon(size).save(ASSET_DIR / f"app_icon_{size}.png")
