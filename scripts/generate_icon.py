#!/usr/bin/env python3
"""
Generates Scout app icon PNGs at 1024x1024 and 512x512.
Design: deep charcoal rounded square, orange gradient map pin,
        white camera aperture circle inside the pin.
"""
import math
from PIL import Image, ImageDraw, ImageFilter
import os

OUT_DIR = os.path.join(os.path.dirname(__file__),
                       "../Scout/Resources/Assets.xcassets/AppIcon.appiconset")

def lerp_color(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))

def draw_icon(size: int) -> Image.Image:
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # --- Background: deep charcoal rounded square ---
    bg_r = s * 0.22          # macOS icon corner radius proportion
    bg_col = (22, 24, 30, 255)
    draw.rounded_rectangle([0, 0, s - 1, s - 1], radius=bg_r, fill=bg_col)

    # --- Map pin shape (tear-drop) ---
    # Pin centre (top of circle part) at ~38% from top, horizontally centred
    cx = s * 0.5
    circle_r = s * 0.265     # radius of the round top of the pin
    circle_cy = s * 0.40     # centre of pin circle

    # Pin tip at bottom
    tip_x = cx
    tip_y = s * 0.76

    # Draw pin as a filled polygon: circle top + triangle narrowing to tip
    # We'll draw it as a path: arc from ~210° to ~330° (bottom of circle) then down to tip
    # Use polygon approximation
    pin_pts = []
    # Top arc (full circle approximation, then we extend to tip)
    num_arc = 60
    for i in range(num_arc + 1):
        angle = math.radians(-210 + (240 * i / num_arc))  # 240° arc (bottom open)
        px = cx + circle_r * math.cos(angle)
        py = circle_cy + circle_r * math.sin(angle)
        pin_pts.append((px, py))
    # Close down to tip
    pin_pts.append((tip_x + s * 0.01, tip_y))
    pin_pts.append((tip_x, tip_y + s * 0.01))
    pin_pts.append((tip_x - s * 0.01, tip_y))

    # Orange gradient fill: draw pin as solid orange, then overlay gradient
    orange_mid = (255, 145, 30, 255)
    orange_hi  = (255, 175, 60, 255)
    orange_lo  = (220, 95,  10, 255)
    draw.polygon(pin_pts, fill=orange_mid)

    # Gradient overlay on pin using a tall gradient image masked to pin shape
    grad = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    grad_draw = ImageDraw.Draw(grad)
    for y in range(s):
        t = y / s
        col = lerp_color(orange_hi, orange_lo, t)
        grad_draw.line([(0, y), (s, y)], fill=col)
    pin_mask = Image.new("L", (s, s), 0)
    mask_draw = ImageDraw.Draw(pin_mask)
    mask_draw.polygon(pin_pts, fill=255)
    img.paste(grad, (0, 0), pin_mask)

    # --- Camera aperture hole inside the pin circle ---
    # Outer white ring + inner dark circle → looks like a lens/aperture
    outer_r = circle_r * 0.55
    inner_r = circle_r * 0.30
    cx_f, cy_f = cx, circle_cy

    # Subtle drop shadow for the aperture
    shadow_off = s * 0.008
    draw2 = ImageDraw.Draw(img)
    draw2.ellipse(
        [cx_f - outer_r + shadow_off, cy_f - outer_r + shadow_off,
         cx_f + outer_r + shadow_off, cy_f + outer_r + shadow_off],
        fill=(0, 0, 0, 60)
    )

    # White outer ring
    draw2.ellipse(
        [cx_f - outer_r, cy_f - outer_r, cx_f + outer_r, cy_f + outer_r],
        fill=(255, 255, 255, 255)
    )

    # Dark inner circle (the "lens")
    lens_col = (30, 32, 40, 255)
    draw2.ellipse(
        [cx_f - inner_r, cy_f - inner_r, cx_f + inner_r, cy_f + inner_r],
        fill=lens_col
    )

    # Tiny specular highlight on lens
    hi_r = inner_r * 0.32
    hi_x = cx_f - inner_r * 0.28
    hi_y = cy_f - inner_r * 0.28
    draw2.ellipse(
        [hi_x - hi_r, hi_y - hi_r, hi_x + hi_r, hi_y + hi_r],
        fill=(255, 255, 255, 90)
    )

    return img

os.makedirs(OUT_DIR, exist_ok=True)

icon_1024 = draw_icon(1024)
icon_1024.save(os.path.join(OUT_DIR, "AppIcon-1024.png"))
print("Saved AppIcon-1024.png")

icon_512 = draw_icon(512)
icon_512.save(os.path.join(OUT_DIR, "AppIcon-512.png"))
print("Saved AppIcon-512.png")

print("Done.")
