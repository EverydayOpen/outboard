"""Render site/static/og.png (1200x630 social preview: the headline and the Storage Plan card, labelled sample data) and
apple-touch-icon.png (180x180, opaque: iOS fills transparent pixels with black), and copy favicon.png and icon.png from the app icon.

Stdlib only; reuses tools/make_icon.py (the icon master, coverage, compositing and PNG helpers). Text is drawn like the
icon: monoline strokes as signed distance functions (a small geometric font below), so edges get analytic antialiasing.
The numbers are the `plan` demo scenario's (BUILD_PLAN section 9: Xcode build data 41 GB, Ollama models 30 GB, iPhone backups 16 GB,
87 GB in all) and say "Sample data" until real tester numbers exist. Content stays in the middle 630 px so previews that crop to a
square still show the headline.

Run from the repo root (about 2 minutes):  python tools/make_og.py
"""
import math
import os
import shutil
import struct
import zlib
from array import array

import make_icon as icon

W, H = 1200, 630
TOOLS = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(TOOLS, "..", "site", "static")
BG_TOP, BG_BOTTOM = (0.085, 0.105, 0.165), (0.030, 0.040, 0.070)   # blue-graphite, lit from the top
COBALT, COBALT_LOW, ICE = icon.COBALT, icon.COBALT_LOW, icon.ICE
INK, MUTED = (0.94, 0.96, 1.0), (0.66, 0.72, 0.84)
X0, X1 = 80.0, 1120.0                       # content inset

# Text. Keep it to the glyphs in GLYPHS.
TITLE, BADGE = "Outboard", "Sample data"
HEADLINE = ["The big folders,", "on your drive."]
SUBLINES = ["Copied, then compared file by file.", "Your original stays until you confirm."]
CARD = (885.0, 355.0, 230.0, 215.0)         # cx, cy, half width, half height of the Storage Plan card
CARD_HEAD = [("Your Mac could free", 15, 205, MUTED, 0.09), ("up to 87 GB", 27, 258, INK, 0.115)]
CARD_ROWS = [("Xcode build data", "41 GB", 41), ("Ollama models", "30 GB", 30), ("iPhone backups", "16 GB", 16)]   # name, size, GB
CARD_FOOT = [("Measured on this Mac.", 11.5, 520), ("Nothing was moved.", 11.5, 542)]
FOOTER = "Free · Open source · Offline · Not affiliated with any app it lists"


# Glyphs in x-height units, y up from the baseline, as stroke centrelines. Centrelines sit a default half stroke
# (0.1) inside the x-height (T), baseline (B), ascender (A), cap height (C) and descender (D).
T, B, A, C, D = 0.9, 0.1, 1.35, 1.3, -0.4
GLYPHS = {   # ("l", x0, y0, x1, y1) line; ("a", cx, cy, r, deg0, deg1) arc, counterclockwise; ("o", cx, cy, r) dot
    "a": [("a", 0.5, 0.5, 0.4, 0, 360), ("l", 0.9, T, 0.9, B)],
    "b": [("l", 0.1, A, 0.1, B), ("a", 0.5, 0.5, 0.4, 0, 360)],
    "c": [("a", 0.5, 0.5, 0.4, 50, 310)],
    "d": [("a", 0.5, 0.5, 0.4, 0, 360), ("l", 0.9, A, 0.9, B)],
    "e": [("l", 0.1, 0.5, 0.9, 0.5), ("a", 0.5, 0.5, 0.4, 0, 315)],
    "f": [("l", 0.3, B, 0.3, 1.05), ("a", 0.6, 1.05, 0.3, 90, 180), ("l", 0.02, T, 0.56, T)],
    "g": [("a", 0.5, 0.5, 0.4, 0, 360), ("l", 0.9, T, 0.9, 0.0), ("a", 0.5, 0.0, 0.4, 200, 360)],
    "h": [("l", 0.1, A, 0.1, B), ("a", 0.5, 0.5, 0.4, 0, 180), ("l", 0.9, 0.5, 0.9, B)],
    "i": [("l", 0.1, T, 0.1, B), ("o", 0.1, 1.27, 0.125)],
    "k": [("l", 0.1, A, 0.1, B), ("l", 0.78, T, 0.1, 0.32), ("l", 0.36, 0.54, 0.82, B)],
    "l": [("l", 0.1, A, 0.1, B)],
    "m": [("l", 0.1, T, 0.1, B), ("a", 0.4, 0.6, 0.3, 0, 180), ("l", 0.7, 0.6, 0.7, B),
          ("a", 1.0, 0.6, 0.3, 0, 180), ("l", 1.3, 0.6, 1.3, B)],
    "n": [("l", 0.1, T, 0.1, B), ("a", 0.5, 0.5, 0.4, 0, 180), ("l", 0.9, 0.5, 0.9, B)],
    "o": [("a", 0.5, 0.5, 0.4, 0, 360)],
    "p": [("l", 0.1, T, 0.1, D), ("a", 0.5, 0.5, 0.4, 0, 360)],
    "r": [("l", 0.1, T, 0.1, B), ("a", 0.5, 0.5, 0.4, 70, 180)],
    "s": [("a", 0.42, 0.695, 0.205, 30, 270), ("a", 0.42, 0.305, 0.205, 210, 450)],
    "t": [("l", 0.28, 1.22, 0.28, B), ("l", 0.02, T, 0.56, T)],
    "u": [("l", 0.1, T, 0.1, 0.5), ("a", 0.5, 0.5, 0.4, 180, 360), ("l", 0.9, T, 0.9, B)],
    "v": [("l", 0.08, T, 0.48, B), ("l", 0.48, B, 0.88, T)],
    "y": [("l", 0.1, T, 0.5, B), ("l", 0.9, T, 0.25, D)],
    "A": [("l", 0.1, B, 0.62, C), ("l", 0.62, C, 1.14, B), ("l", 0.28, 0.52, 0.96, 0.52)],
    "B": [("l", 0.1, B, 0.1, C), ("l", 0.1, C, 0.55, C), ("a", 0.55, 1.0, 0.3, 270, 450), ("l", 0.1, 0.7, 0.6, 0.7),
          ("a", 0.6, 0.4, 0.3, 270, 450), ("l", 0.6, B, 0.1, B)],
    "C": [("a", 0.72, 0.7, 0.6, 45, 315)],
    "D": [("l", 0.1, B, 0.1, C), ("l", 0.1, C, 0.5, C), ("a", 0.5, 0.7, 0.6, 270, 450), ("l", 0.5, B, 0.1, B)],
    "G": [("a", 0.72, 0.7, 0.6, 45, 360), ("l", 0.8, 0.7, 1.32, 0.7)],
    "K": [("l", 0.1, B, 0.1, C), ("l", 0.98, C, 0.1, 0.42), ("l", 0.44, 0.76, 1.02, B)],
    "L": [("l", 0.1, C, 0.1, B), ("l", 0.1, B, 0.82, B)],
    "M": [("l", 0.1, B, 0.1, C), ("l", 0.1, C, 0.72, 0.3), ("l", 0.72, 0.3, 1.34, C), ("l", 1.34, C, 1.34, B)],
    "N": [("l", 0.1, B, 0.1, C), ("l", 0.1, C, 1.02, B), ("l", 1.02, B, 1.02, C)],
    "O": [("a", 0.7, 0.7, 0.6, 0, 360)],
    "P": [("l", 0.1, B, 0.1, C), ("l", 0.1, C, 0.55, C), ("a", 0.55, 0.97, 0.33, 270, 450), ("l", 0.55, 0.64, 0.1, 0.64)],
    "S": [("a", 0.58, 1.0, 0.3, 30, 270), ("a", 0.58, 0.4, 0.3, 210, 450)],
    "T": [("l", 0.08, C, 1.02, C), ("l", 0.55, C, 0.55, B)],
    "1": [("l", 0.42, C, 0.42, B), ("l", 0.12, 1.05, 0.42, C)],
    "2": [("a", 0.5, 0.97, 0.33, 320, 520), ("l", 0.753, 0.758, 0.1, B), ("l", 0.1, B, 0.9, B)],
    "3": [("a", 0.48, 1.0, 0.3, 270, 510), ("a", 0.48, 0.4, 0.3, 210, 450)],
    "5": [("l", 0.86, C, 0.22, C), ("l", 0.22, C, 0.237, 0.668), ("a", 0.52, 0.43, 0.37, 220, 500)],
    "7": [("l", 0.1, C, 0.92, C), ("l", 0.92, C, 0.36, B)],
    "8": [("a", 0.5, 1.02, 0.28, 0, 360), ("a", 0.5, 0.42, 0.32, 0, 360)],
    "9": [("a", 0.5, 0.95, 0.35, 0, 360), ("l", 0.84, 0.86, 0.44, B)],
    ",": [("l", 0.12, 0.14, 0.02, -0.2)],
    "%": [("a", 0.28, 1.06, 0.2, 0, 360), ("a", 0.9, 0.34, 0.2, 0, 360), ("l", 1.02, C, 0.16, B)],
    "·": [("o", 0.1, 0.5, 0.1)],
    ".": [("o", 0.12, B, 0.115)],
    "4": [("l", 0.78, B, 0.78, C), ("l", 0.78, C, 0.08, 0.45), ("l", 0.08, 0.45, 0.98, 0.45)],
    "F": [("l", 0.1, B, 0.1, C), ("l", 0.1, C, 0.82, C), ("l", 0.1, 0.76, 0.7, 0.76)],
    "I": [("l", 0.1, B, 0.1, C)],
    "X": [("l", 0.1, C, 0.98, B), ("l", 0.98, C, 0.1, B)],
    "Y": [("l", 0.1, C, 0.58, 0.72), ("l", 1.06, C, 0.58, 0.72), ("l", 0.58, 0.72, 0.58, B)],
    "w": [("l", 0.05, T, 0.3, B), ("l", 0.3, B, 0.55, 0.7), ("l", 0.55, 0.7, 0.8, B), ("l", 0.8, B, 1.05, T)],
    "x": [("l", 0.08, T, 0.88, B), ("l", 0.08, B, 0.88, T)],
    "U": [("l", 0.1, C, 0.1, 0.55), ("a", 0.58, 0.55, 0.48, 180, 360), ("l", 1.06, 0.55, 1.06, C)],
    "6": [("a", 0.5, 0.42, 0.35, 0, 360), ("l", 0.15, 0.45, 0.62, C)],
    "0": [("l", 0.12, 0.4, 0.12, 0.9), ("l", 0.88, 0.4, 0.88, 0.9), ("a", 0.5, 0.9, 0.38, 0, 180), ("a", 0.5, 0.4, 0.38, 180, 360)],
}
GAP, SPACE = 0.14, 0.6   # between the visual edges of neighbouring glyphs; a space's width


def arc_points(s):
    _, cx, cy, r, a0, a1 = s
    return [(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))
            for a in list(range(int(a0), int(a1), 5)) + [a1]]


def stroke_dist(s, x, y, w):
    """Distance from (x, y) to stroke s with half width w (x-height units)."""
    if s[0] == "l":
        return icon.seg(x, y, *s[1:]) - w
    if s[0] == "o":
        return math.hypot(x - s[1], y - s[2]) - s[3]
    _, cx, cy, r, a0, a1 = s
    ang = math.degrees(math.atan2(y - cy, x - cx)) % 360
    if a1 - a0 >= 360 or a0 <= ang <= a1 or ang + 360 <= a1:
        return abs(math.hypot(x - cx, y - cy) - r) - w
    ends = [(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))) for a in (a0, a1)]
    return min(math.hypot(x - ex, y - ey) for ex, ey in ends) - w


def x_extent(strokes, w):
    xs = []
    for s in strokes:
        if s[0] == "l":
            xs += [s[1] - w, s[3] - w, s[1] + w, s[3] + w]
        elif s[0] == "o":
            xs += [s[1] - s[3], s[1] + s[3]]
        else:
            xs += [x + d for x, _ in arc_points(s) for d in (-w, w)]
    return min(xs), max(xs)


def layout(text, w):
    """[(x offset, strokes, left, right)] in x-height units, and the total width."""
    placed, pen = [], 0.0
    for ch in text:
        if ch == " ":
            pen += SPACE - GAP
            continue
        lo, hi = x_extent(GLYPHS[ch], w)
        placed.append((pen - lo, GLYPHS[ch], pen, pen + hi - lo))
        pen += hi - lo + GAP
    return placed, pen - GAP


def text(px, s, x0, baseline, xh, colour, weight=0.1):
    """Draw s with its left edge at x0 and its baseline at `baseline` (pixels); returns the right edge."""
    placed, width = layout(s, weight)
    for y in range(int(baseline - (A + weight) * xh) - 2, int(baseline - (D - weight) * xh) + 3):
        v = (baseline - y - 0.5) / xh
        for x in range(int(x0) - 2, int(x0 + width * xh) + 3):
            u = (x + 0.5 - x0) / xh
            d = min((stroke_dist(st, u - off, v, weight) for off, strokes, lo, hi in placed
                     if lo - 0.2 <= u <= hi + 0.2 for st in strokes), default=1e9)
            a = icon.cov(d * xh)
            if a:
                icon.over(px, (y * W + x) * 4, *colour, a)
    return x0 + width * xh


def resample(px, n, m):
    """Bilinear n -> m on a premultiplied square buffer (used for m > n / 2, then halved)."""
    out = array("f", bytes(m * m * 16))
    k = n / m
    for y in range(m):
        sy = min(n - 1.0, max(0.0, (y + 0.5) * k - 0.5))
        y0 = int(sy)
        y1, fy = min(y0 + 1, n - 1), sy - y0
        for x in range(m):
            sx = min(n - 1.0, max(0.0, (x + 0.5) * k - 0.5))
            x0 = int(sx)
            x1, fx = min(x0 + 1, n - 1), sx - x0
            i00, i01, i10, i11 = (y0 * n + x0) * 4, (y0 * n + x1) * 4, (y1 * n + x0) * 4, (y1 * n + x1) * 4
            o = (y * m + x) * 4
            for c in range(4):
                top = px[i00 + c] + (px[i01 + c] - px[i00 + c]) * fx
                bot = px[i10 + c] + (px[i11 + c] - px[i10 + c]) * fx
                out[o + c] = top + (bot - top) * fy
    return out


def width(s, xh, weight=0.1):
    return layout(s, weight)[1] * xh


def card(px):
    """The plan card: soft shadow, graphite panel, lit top edge, and the icon's cobalt bar down its left edge."""
    cx, cy, hw, hh = CARD
    r, k = 22.0, 1 / (28.0 * math.sqrt(2))
    for y in range(max(0, int(cy - hh) - 70), min(H, int(cy + hh) + 90)):
        for x in range(max(0, int(cx - hw) - 70), min(W, int(cx + hw) + 70)):
            i = (y * W + x) * 4
            fx, fy = x + 0.5, y + 0.5
            icon.over(px, i, 0.0, 0.0, 0.0, 0.55 * 0.5 * math.erfc(icon.rrect(fx, fy - 30, cx, cy, hw - 4, hh, r) * k))
            d = icon.rrect(fx, fy, cx, cy, hw, hh, r)
            t = (fy - (cy - hh)) / (2 * hh)
            icon.over(px, i, *icon.mix((0.150, 0.190, 0.280), (0.100, 0.130, 0.205), t), icon.cov(d))
            lit = max(0.0, 1.0 - (fy - (cy - hh)) / 22.0)
            icon.over(px, i, 1.0, 1.0, 1.0, 0.22 * lit * icon.cov(abs(d + 1.2) - 1.2))
            icon.over(px, i, 1.0, 1.0, 1.0, 0.07 * icon.cov(abs(d + 0.6) - 0.6))
    for y in range(int(cy - hh) + 26, int(cy + hh) - 25):
        for x in range(int(cx - hw) + 14, int(cx - hw) + 20):
            icon.over(px, (y * W + x) * 4, *icon.mix(COBALT, COBALT_LOW, (y - (cy - hh)) / (2 * hh)), 0.95)


def bar(px, x0, y0, w, h, colour):
    """A rounded bar whose width is proportional to the unrounded bytes (BUILD_PLAN section 8: never truncated, always proportional)."""
    for y in range(int(y0) - 2, int(y0 + h) + 3):
        for x in range(int(x0) - 2, int(x0 + w) + 3):
            icon.over(px, (y * W + x) * 4, *colour, icon.cov(icon.rrect(x + 0.5, y + 0.5, x0 + w / 2, y0 + h / 2, w / 2, h / 2, h / 2)))


def render(master):
    px = array("f", bytes(W * H * 16))
    for y in range(H):
        base = [BG_TOP[c] + (BG_BOTTOM[c] - BG_TOP[c]) * y / (H - 1) for c in range(3)]
        for x in range(W):
            i = (y * W + x) * 4
            px[i:i + 4] = array("f", base + [1.0])
            g = max(0.0, 1.0 - math.hypot((x - 890) / 1.6, y - 380) / 360) ** 2 * 0.22   # cobalt glow behind the card
            if g:
                icon.over(px, i, *icon.HAZE, g)

    # Header: the app icon (1024 master -> bilinear to 2x -> 2x2 box filter), name and the sample-data pill.
    size, top = 64, 56
    small = icon.half(resample(master, icon.N, 2 * size), 2 * size)
    for y in range(size):
        for x in range(size):
            s, d = (y * size + x) * 4, ((top + y) * W + int(X0) + x) * 4
            k = 1.0 - small[s + 3]
            for c in range(4):
                px[d + c] = small[s + c] + px[d + c] * k
    text(px, TITLE, X0 + size + 18, 100, 22, INK, 0.11)
    bw = width(BADGE, 12.5, 0.09)
    pill = (X1 - bw / 2 - 16, 88.0, bw / 2 + 16, 17.0)
    for y in range(66, 112):
        for x in range(int(X1 - bw - 40), int(X1) + 4):
            d = icon.rrect(x + 0.5, y + 0.5, *pill, 17.0)
            icon.over(px, (y * W + x) * 4, *MUTED, 0.55 * icon.cov(abs(d + 0.6) - 0.6))
    text(px, BADGE, X1 - bw - 16, 93, 12.5, MUTED, 0.09)

    for n, line in enumerate(HEADLINE):
        text(px, line, X0, 250 + n * 70, 38, INK, 0.115)
    for n, line in enumerate(SUBLINES):
        text(px, line, X0, 376 + n * 34, 17, MUTED, 0.095)

    card(px)
    cx, cy, hw, hh = CARD
    left, right = cx - hw + 40, cx + hw - 36
    for line, xh, base, colour, weight in CARD_HEAD:
        text(px, line, left, base, xh, colour, weight)
    biggest = max(gb for _, _, gb in CARD_ROWS)
    for n, (name, size_text, gb) in enumerate(CARD_ROWS):
        base = 322 + n * 62
        text(px, name, left, base, 14, INK, 0.1)
        text(px, size_text, right - width(size_text, 14, 0.1), base, 14, INK, 0.1)
        bar(px, left, base + 16, (right - left) * gb / biggest, 9, icon.mix(COBALT, COBALT_LOW, n / 3))
    for line, xh, base in CARD_FOOT:
        text(px, line, left, base, xh, MUTED, 0.09)
    text(px, FOOTER, X0, 604, 11.5, MUTED, 0.09)
    return px


def write_png(path, px, w, h):
    """Opaque RGB PNG."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        row = px[y * w * 4:(y + 1) * w * 4]
        for x in range(w):
            raw += bytes(min(255, int(row[4 * x + c] * 255 + 0.5)) for c in range(3))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"sRGB", b"\0"))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


def main():
    os.makedirs(STATIC, exist_ok=True)
    shutil.copyfile(os.path.join(icon.OUT, "icon_32x32@2x.png"), os.path.join(STATIC, "favicon.png"))
    shutil.copyfile(os.path.join(icon.OUT, "icon_128x128@2x.png"), os.path.join(STATIC, "icon.png"))
    master = icon.render()
    # 180 px (Apple's size) on white; the macOS icon's ~10% margin gives iOS's mask room around the artwork.
    touch = icon.half(resample(master, icon.N, 360), 360)
    for i in range(0, len(touch), 4):
        k = 1.0 - touch[i + 3]   # premultiplied "over" white: c + (1 - a)
        for c in range(3):
            touch[i + c] += k
    write_png(os.path.join(STATIC, "apple-touch-icon.png"), touch, 180, 180)
    write_png(os.path.join(STATIC, "og.png"), render(master), W, H)
    print(f"wrote og.png, favicon.png, icon.png, apple-touch-icon.png to {os.path.normpath(STATIC)}")


if __name__ == "__main__":
    main()
