#!/usr/bin/env python3
"""Generate opaque SendHere app icons for iOS and Android."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
IOS_DIR = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
ANDROID_RES = ROOT / "android/app/src/main/res"
SCALE = 4
BLUE = "#4658D6"
WHITE = "#FFFFFF"

IOS_ICONS = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

ANDROID_ICONS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def draw_rounded_line(draw, points, width, fill):
    draw.line(points, fill=fill, width=width, joint="curve")
    radius = width / 2
    for x, y in points:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def make_icon(size: int) -> Image.Image:
    canvas = size * SCALE
    # iOS app icons must be opaque. The OS applies its own rounded mask; baking
    # transparent corners into the image produces a visible black outer plate.
    image = Image.new("RGB", (canvas, canvas), BLUE)
    draw = ImageDraw.Draw(image)
    y = canvas * 0.5
    left_tip, right_tip = canvas * 0.25, canvas * 0.75
    shaft_left, shaft_right = canvas * 0.36, canvas * 0.64
    wing = canvas * 0.10
    stroke = max(2, round(canvas * 0.065))
    draw_rounded_line(draw, [(left_tip, y), (right_tip, y)], stroke, WHITE)
    draw_rounded_line(
        draw,
        [(shaft_left, y - wing), (left_tip, y), (shaft_left, y + wing)],
        stroke,
        WHITE,
    )
    draw_rounded_line(
        draw,
        [(shaft_right, y - wing), (right_tip, y), (shaft_right, y + wing)],
        stroke,
        WHITE,
    )
    return image.resize((size, size), Image.Resampling.LANCZOS)


for filename, size in IOS_ICONS.items():
    make_icon(size).save(IOS_DIR / filename)

for directory, size in ANDROID_ICONS.items():
    make_icon(size).save(ANDROID_RES / directory / "ic_launcher.png")
