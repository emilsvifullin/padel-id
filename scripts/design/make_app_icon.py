#!/usr/bin/env python3
"""Renders the Padel ID app icon (light, dark and tinted appearances).

The mark matches BrandMark in the app: a ball inside the six-sided Padel DNA
hexagon on a court-blue field. Rendered at 4x and downsampled for clean edges.

Usage: python3 scripts/design/make_app_icon.py <AppIcon.appiconset dir>
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4
S = SIZE * SCALE

BLUE_TOP = (64, 112, 255)
BLUE_BOTTOM = (22, 58, 196)
BALL = (212, 238, 64)
BALL_SHADE = (176, 204, 36)


def hexagon(cx, cy, r):
    return [(cx + r * math.cos(math.radians(-90 + 60 * i)), cy + r * math.sin(math.radians(-90 + 60 * i))) for i in range(6)]


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        img.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img.resize((size, size))


def mask_from(draw_fn):
    m = Image.new("L", (S, S), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def ball_layers(cx, cy, r, ball_rgb, shade_rgb, seam_rgba):
    """Returns (rgba image, mask) of the ball with two curved seams."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    disc = mask_from(lambda d: d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255))
    # Base colour with a soft lower shade for volume.
    shade = Image.new("RGBA", (S, S), shade_rgb + (255,))
    base = Image.new("RGBA", (S, S), ball_rgb + (255,))
    light = mask_from(lambda d: d.ellipse([cx - r * 1.25, cy - r * 1.35, cx + r * 0.9, cy + r * 0.75], fill=255))
    light = light.filter(ImageFilter.GaussianBlur(r * 0.35))
    body = Image.composite(base, shade, light)
    layer.paste(body, (0, 0), disc)
    # Seams: arcs of large circles left and right of the ball, clipped to it.
    seam = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(seam)
    width = int(r * 0.12)
    big = r * 1.0
    off = r * 1.48
    sd.ellipse([cx - off - big, cy - big, cx - off + big, cy + big], outline=255, width=width)
    sd.ellipse([cx + off - big, cy - big, cx + off + big, cy + big], outline=255, width=width)
    seam = ImageChops.multiply(seam, disc)
    seam_img = Image.new("RGBA", (S, S), seam_rgba)
    seam_alpha = seam.point(lambda v: v * seam_rgba[3] // 255)
    layer.paste(seam_img, (0, 0), seam_alpha)
    return layer, disc


def render(appearance):
    cx = cy = S / 2
    hex_r = S * 0.335
    ball_r = S * 0.158
    if appearance == "light":
        canvas = vertical_gradient(S, BLUE_TOP, BLUE_BOTTOM).convert("RGBA")
        hex_fill = (255, 255, 255, 46)
        hex_line = (255, 255, 255, 235)
        ball_rgb, shade_rgb, seam = BALL, BALL_SHADE, (255, 255, 255, 240)
    elif appearance == "dark":
        canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        hex_fill = (91, 131, 255, 70)
        hex_line = (120, 156, 255, 255)
        ball_rgb, shade_rgb, seam = (217, 244, 90), (186, 214, 52), (20, 24, 40, 255)
    else:  # tinted: grayscale artwork, the system applies the tint
        canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        hex_fill = (255, 255, 255, 40)
        hex_line = (255, 255, 255, 255)
        ball_rgb, shade_rgb, seam = (236, 236, 236), (200, 200, 200), (60, 60, 60, 255)

    pts = hexagon(cx, cy, hex_r)
    fill_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(fill_layer).polygon(pts, fill=hex_fill)
    canvas = Image.alpha_composite(canvas, fill_layer)
    line_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(line_layer)
    line_w = int(S * 0.034)
    ld.line(pts + [pts[0]], fill=hex_line, width=line_w, joint="curve")
    for p in pts:
        ld.ellipse([p[0] - line_w / 2, p[1] - line_w / 2, p[0] + line_w / 2, p[1] + line_w / 2], fill=hex_line)
    canvas = Image.alpha_composite(canvas, line_layer)

    if appearance == "light":
        shadow = mask_from(lambda d: d.ellipse([cx - ball_r, cy - ball_r + S * 0.02, cx + ball_r, cy + ball_r + S * 0.02], fill=110))
        shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.02))
        canvas = Image.alpha_composite(canvas, Image.merge("RGBA", (Image.new("L", (S, S), 8),) * 3 + (shadow,)))

    ball, _ = ball_layers(cx, cy, ball_r, ball_rgb, shade_rgb, seam)
    canvas = Image.alpha_composite(canvas, ball)
    out = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    if appearance == "light":
        out = out.convert("RGB")  # the primary icon must be opaque
    return out


def main():
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    for name in ("light", "dark", "tinted"):
        render(name).save(target / f"AppIcon-{name}.png", optimize=True)


if __name__ == "__main__":
    main()
