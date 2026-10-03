"""Render the Outboard app icon and write App/Assets.xcassets/AppIcon.appiconset.

Stdlib only (no Pillow). Shapes are signed distance functions, so every edge gets exact analytic antialiasing at
1024 px; smaller sizes are box-filtered down from the 1024 master in premultiplied alpha.

Layout follows the macOS (Big Sur and later) icon grid: 1024 canvas, 824 px body with continuous-looking corners, soft
drop shadow. The drawing is a laptop and a drive: a pale display outline with a notch cut out of the middle of its bottom
edge and of the base bar beneath it, a cobalt arrow that starts inside the display, drops through the notch, and lands on a
cobalt drive slab (with a small light and a slot) at the bottom. The body is blue-graphite, lit from the top. It reads at
16 px as a dark square, a pale outline with a gap and a cobalt slab.

Run from the repo root (about a minute):  python tools/make_icon.py
"""
import json
import math
import os
import struct
import zlib
from array import array

N = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "App", "Assets.xcassets", "AppIcon.appiconset")

# Body: 824 px square centred on the canvas. A p=3 superellipse corner with a larger radius approximates Apple's
# continuous corner (curvature ramps in instead of jumping like a circle).
HALF, CORNER, P = 412.0, 278.0, 3.0
TOP, BOTTOM = (0.170, 0.222, 0.310), (0.070, 0.090, 0.135)    # #2B384F -> #121722, blue-graphite lit from above

# Colours shared with tools/make_og.py (it imports these).
ICE, ICE_LOW = (0.88, 0.93, 1.0), (0.70, 0.80, 0.96)          # the laptop's strokes, light at the top
COBALT, COBALT_LOW = (0.56, 0.69, 1.0), (0.24, 0.43, 0.90)    # the drive slab, light at the top
ARROW = (0.62, 0.74, 1.0)
HAZE = (0.30, 0.50, 1.0)

# --- geometry (canvas units; y down) ---
CX = 512.0
# The display: a rounded rectangle stroked 40 wide, open in the middle of its bottom edge.
S_CY, S_HW, S_HH, S_R, S_W = 335.0, 215.0, 135.0, 48.0, 20.0     # centre y, half width, half height, corner radius, half stroke
GAP = 80.0                                                       # the notch: the strokes end this far from the centre line
# The base bar beneath it, 34 thick, with the same notch.
B_Y, B_HW, B_R = 529.0, 258.0, 17.0
# The arrow: shaft and head, 42 wide.
A_TOP, A_NECK, A_TIP, A_ARM, A_R = 285.0, 632.0, 668.0, 62.0, 22.0
# The drive slab.
D_CY, D_HW, D_HH, D_R = 782.0, 215.0, 62.0, 36.0


def cov(d):
    """Pixel coverage from a signed distance in pixels (negative = inside)."""
    return 0.0 if d >= 0.5 else 1.0 if d <= -0.5 else 0.5 - d


def seg(px, py, ax, ay, bx, by):
    """Distance from (px, py) to segment a-b."""
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def rrect(x, y, cx, cy, hw, hh, r):
    """Signed distance to a rounded rectangle."""
    qx, qy = abs(x - cx) - hw + r, abs(y - cy) - hh + r
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def body_sdf(x, y):
    qx, qy = abs(x - 512.0) - (HALF - CORNER), abs(y - 512.0) - (HALF - CORNER)
    if qx > 0 and qy > 0:
        return (qx ** P + qy ** P) ** (1 / P) - CORNER
    return max(qx, qy) - CORNER


def over(px, i, r, g, b, a):
    """Composite straight-alpha colour (r, g, b, a) over premultiplied pixel i."""
    k = 1.0 - a
    px[i] = r * a + px[i] * k
    px[i + 1] = g * a + px[i + 1] * k
    px[i + 2] = b * a + px[i + 2] * k
    px[i + 3] = a + px[i + 3] * k


def mix(a, b, t):
    t = min(1.0, max(0.0, t))
    return [a[c] + (b[c] - a[c]) * t for c in range(3)]


def capsule(x, y, ax, ay, bx, by, r):
    return seg(x, y, ax, ay, bx, by) - r


def laptop_sdf(x, y):
    """Signed distance to the display outline and the base bar, both with the notch."""
    cl, cr = CX - S_HW + S_R, CX + S_HW - S_R              # where the corner arcs start on the top and bottom runs
    top, bot = S_CY - S_HH, S_CY + S_HH
    left, right = CX - S_HW, CX + S_HW
    ctop, cbot = top + S_R, bot - S_R
    d = capsule(x, y, cl, top, cr, top, S_W)                # top run
    d = min(d, capsule(x, y, left, ctop, left, cbot, S_W), capsule(x, y, right, ctop, right, cbot, S_W))   # sides
    d = min(d, capsule(x, y, cl, bot, CX - GAP, bot, S_W), capsule(x, y, CX + GAP, bot, cr, bot, S_W))      # bottom run, two stubs
    for cx, cy, sx, sy in ((cl, ctop, -1, -1), (cr, ctop, 1, -1), (cl, cbot, -1, 1), (cr, cbot, 1, 1)):    # the four corner arcs
        if (x - cx) * sx >= 0 and (y - cy) * sy >= 0:
            d = min(d, abs(math.hypot(x - cx, y - cy) - S_R) - S_W)
    d = min(d, capsule(x, y, CX - B_HW + B_R, B_Y, CX - GAP, B_Y, B_R), capsule(x, y, CX + GAP, B_Y, CX + B_HW - B_R, B_Y, B_R))
    return d


def arrow_sdf(x, y):
    d = capsule(x, y, CX, A_TOP, CX, A_NECK, A_R)
    return min(d, capsule(x, y, CX, A_TIP, CX - A_ARM, A_NECK - 26, A_R), capsule(x, y, CX, A_TIP, CX + A_ARM, A_NECK - 26, A_R))


def drive_sdf(x, y, dy=0.0):
    return rrect(x, y - dy, CX, D_CY, D_HW, D_HH, D_R)


def render():
    px = array("f", bytes(N * N * 16))
    shadow_k = 1 / (14.0 * math.sqrt(2))       # body shadow: sigma 14 px, 10 px down, 32 %
    drive_k = 1 / (16.0 * math.sqrt(2))        # the slab's shadow: sigma 16 px, 16 px down, 55 %
    for yi in range(60, N - 40):
        y = yi + 0.5
        base = mix(TOP, BOTTOM, (y - 100) / 824)
        for xi in range(60, N - 60):
            x = xi + 0.5
            i = (yi * N + xi) * 4
            d_body = body_sdf(x, y)
            if d_body > -1:
                a = 0.32 * 0.5 * math.erfc(body_sdf(x, y - 10) * shadow_k)
                if a > 1 / 1024:
                    over(px, i, 0.0, 0.0, 0.0, a)
            a = cov(d_body)
            if a == 0.0:
                continue
            glow = max(0.0, 1.0 - ((x - 512) ** 2 + (y - 120) ** 2) / 700.0 ** 2) * 0.09   # the quay lamp: a faint highlight at the top
            over(px, i, *mix(base, (1, 1, 1), glow), a)
            hz = math.exp(-(((x - 512) / 230.0) ** 2 + ((y - 560) / 300.0) ** 2))          # a cobalt haze behind the arrow
            over(px, i, *HAZE, 0.20 * hz * a)
            over(px, i, 1.0, 1.0, 1.0, 0.10 * cov(abs(d_body + 2.0) - 1.5))                # thin rim: keeps the edge on dark Docks
            if 200 < x < 830 and 160 < y < 900:
                # the drive slab's shadow, then the slab, then the strokes
                if abs(x - CX) < D_HW + 70 and 640 < y < 920:
                    over(px, i, 0.0, 0.0, 0.0, 0.55 * 0.5 * math.erfc(drive_sdf(x, y, 16.0) * drive_k) * a)
                d = laptop_sdf(x, y)
                if d < 1:
                    t = (y - (S_CY - S_HH)) / (B_Y - (S_CY - S_HH) + 20)
                    over(px, i, *mix(ICE, ICE_LOW, t), cov(d) * a)
                    lit = max(0.0, 1.0 - (y - (S_CY - S_HH - S_W)) / 30.0)
                    over(px, i, 1.0, 1.0, 1.0, 0.35 * lit * cov(abs(d + 2.5) - 2.0) * a)   # the specular edge on the top run
                d = arrow_sdf(x, y)
                if d < 1:
                    over(px, i, *ARROW, cov(d) * a)
                d = drive_sdf(x, y)
                if d < 1:
                    t = (y - (D_CY - D_HH)) / (2 * D_HH)
                    over(px, i, *mix(COBALT, COBALT_LOW, t), cov(d) * a)
                    lit = max(0.0, 1.0 - (y - (D_CY - D_HH)) / 26.0)
                    over(px, i, 1.0, 1.0, 1.0, 0.50 * lit * cov(abs(d + 2.0) - 2.0))      # the specular edge on the slab
                    led = math.hypot(x - (CX + D_HW - 62.0), y - D_CY) - 13.0
                    over(px, i, 0.05, 0.10, 0.28, 0.62 * cov(led))                         # the drive's light
                    slot = capsule(x, y, CX - 150.0, D_CY, CX - 20.0, D_CY, 6.0)
                    over(px, i, 0.05, 0.10, 0.28, 0.30 * cov(slot))                        # its slot
    return px


def half(px, n):
    """2x2 box filter (premultiplied, so edges don't darken)."""
    m = n // 2
    out = array("f", bytes(m * m * 16))
    row = n * 4
    for y in range(m):
        r0 = 2 * y * row
        r1 = r0 + row
        o = y * m * 4
        for x in range(m):
            i, j, k = r0 + 8 * x, r1 + 8 * x, o + 4 * x
            for c in range(4):
                out[k + c] = (px[i + c] + px[i + 4 + c] + px[j + c] + px[j + 4 + c]) * 0.25
    return out


def write_png(path, px, n):
    raw = bytearray()
    for y in range(n):
        raw.append(0)  # filter: none
        for x in range(n):
            i = (y * n + x) * 4
            a = px[i + 3]
            if a < 1 / 512:
                raw += b"\0\0\0\0"
                continue
            raw += bytes(min(255, int(px[i + c] / a * 255 + 0.5)) for c in range(3))
            raw.append(min(255, int(a * 255 + 0.5)))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0)))
        f.write(chunk(b"sRGB", b"\0"))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


def main():
    os.makedirs(OUT, exist_ok=True)
    images, by_size = [], {N: render()}
    n = N
    while n > 16:
        by_size[n // 2] = half(by_size[n], n)
        n //= 2
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            write_png(os.path.join(OUT, name), by_size[pt * scale], pt * scale)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    with open(os.path.join(OUT, "Contents.json"), "w", newline="\n") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    with open(os.path.join(OUT, "..", "Contents.json"), "w", newline="\n") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    print(f"wrote {len(images)} PNGs to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
