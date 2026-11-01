"""Generates src/BackupSyncGui/Assets/App.ico (and a PNG preview).

The mark is a two-arrow synchronisation ring drawn in white on the application's
accent gradient: it reads as "synchronize", which is the app's only action, and it
survives down to 16 px because it is a single bold shape.

Run from the repository root:
    python tools/generate-icon.py

No third-party dependencies beyond Pillow. Every size is rendered natively at 8x
and downsampled, and the ICO container is written by hand with PNG payloads so
each entry keeps its own rendering quality.
"""

import os
import struct
from io import BytesIO
from math import cos, radians, sin

from PIL import Image, ImageDraw

SUPERSAMPLE = 8
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]

# Application accent, matching Themes/DarkTheme.xaml (AccentBrush / AccentPressedBrush)
GRADIENT_TOP = (94, 159, 255)
GRADIENT_BOTTOM = (52, 104, 199)
GLYPH = (255, 255, 255, 255)
TILE_RADIUS_RATIO = 0.215

# Ring geometry as a fraction of the icon edge. The stroke is deliberately bold:
# at 16 px it still resolves to roughly two pixels.
RING_RADIUS = 0.300
RING_STROKE = 0.105
ARC_TOP = (188.0, 326.0)
ARC_BOTTOM = (8.0, 146.0)

# Arrow head: the base straddles the stroke, the tip travels along the circle
ARROW_HALF_WIDTH = 0.098
ARROW_LENGTH = 0.130


def vertical_gradient(width, height, top, bottom):
    gradient = Image.new("RGB", (1, height))
    for y in range(height):
        factor = y / max(height - 1, 1)
        gradient.putpixel(
            (0, y),
            (
                round(top[0] + (bottom[0] - top[0]) * factor),
                round(top[1] + (bottom[1] - top[1]) * factor),
                round(top[2] + (bottom[2] - top[2]) * factor),
            ),
        )
    return gradient.resize((width, height), Image.Resampling.BICUBIC)


def polar(center_x, center_y, radius, angle_degrees):
    angle = radians(angle_degrees)
    return center_x + radius * cos(angle), center_y + radius * sin(angle)


def draw_arrow_head(draw, center_x, center_y, radius, end_angle, edge):
    """Compact triangle anchored on the arc end, pointing along the sweep.

    The base straddles the stroke radially and the tip travels further along the
    same circle, so the head never juts outside the ring like a spike.
    """
    half_width = ARROW_HALF_WIDTH * edge
    tip_angle = end_angle + (ARROW_LENGTH * edge / radius) * 57.29577951
    base_angle = end_angle - 1.5

    tip = polar(center_x, center_y, radius, tip_angle)
    outer = polar(center_x, center_y, radius + half_width, base_angle)
    inner = polar(center_x, center_y, radius - half_width, base_angle)
    draw.polygon([tip, outer, inner], fill=GLYPH)


def render(size):
    edge = size * SUPERSAMPLE
    canvas = Image.new("RGBA", (edge, edge), (0, 0, 0, 0))

    # Rounded tile carrying the accent gradient
    gradient = vertical_gradient(edge, edge, GRADIENT_TOP, GRADIENT_BOTTOM)
    tile_mask = Image.new("L", (edge, edge), 0)
    ImageDraw.Draw(tile_mask).rounded_rectangle(
        [0, 0, edge - 1, edge - 1],
        radius=int(edge * TILE_RADIUS_RATIO),
        fill=255,
    )
    canvas.paste(gradient, (0, 0), tile_mask)

    # Synchronisation ring: two arcs, each closed by an arrow head
    glyph = Image.new("RGBA", (edge, edge), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glyph)
    radius = RING_RADIUS * edge
    center_x = center_y = edge / 2.0
    box = [center_x - radius, center_y - radius, center_x + radius, center_y + radius]
    stroke = int(RING_STROKE * edge)
    for start, end in (ARC_TOP, ARC_BOTTOM):
        draw.arc(box, start=start, end=end, fill=GLYPH, width=stroke)
    draw_arrow_head(draw, center_x, center_y, radius, ARC_TOP[1], edge)
    draw_arrow_head(draw, center_x, center_y, radius, ARC_BOTTOM[1], edge)

    canvas.alpha_composite(glyph)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def write_ico(path, images):
    payloads = []
    for image in images:
        buffer = BytesIO()
        image.save(buffer, format="PNG", optimize=True)
        payloads.append((image.width, buffer.getvalue()))

    offset = 6 + 16 * len(payloads)
    directory = bytearray()
    blobs = bytearray()
    for width, data in payloads:
        dimension = 0 if width >= 256 else width
        directory += struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)

    with open(path, "wb") as handle:
        handle.write(struct.pack("<HHH", 0, 1, len(payloads)))
        handle.write(directory)
        handle.write(blobs)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    assets = os.path.join(root, "src", "BackupSyncGui", "Assets")
    os.makedirs(assets, exist_ok=True)

    images = [render(size) for size in SIZES]
    ico_path = os.path.join(assets, "App.ico")
    write_ico(ico_path, images)
    print("wrote", ico_path, os.path.getsize(ico_path), "bytes")

    preview = os.path.join(assets, "App-256.png")
    images[-1].save(preview, format="PNG", optimize=True)
    print("wrote", preview, os.path.getsize(preview), "bytes")

    for size in (256, 48, 32, 16):
        image = images[SIZES.index(size)]
        pixels = image.load()
        opaque = 0
        white = 0
        for y in range(size):
            for x in range(size):
                red, green, blue, alpha = pixels[x, y]
                if alpha > 128:
                    opaque += 1
                    if min(red, green, blue) > 200:
                        white += 1
        print(f"  {size:3d}px opaque {opaque * 100 // (size * size):2d}%  white glyph {white * 100 // max(opaque, 1):2d}%")


if __name__ == "__main__":
    main()
