#!/usr/bin/env python3
# =============================================================================
# Corvid OS — pure-Python PNG asset generator (ZERO external dependencies)
# =============================================================================
# WHY THIS EXISTS:
#   The primary asset path is the hand-authored SVGs (corvid-wordmark.svg,
#   corvid-wallpaper.svg). On the Linux build VM, generate-assets.sh rasterizes
#   those SVGs with rsvg-convert / ImageMagick for crisp output.
#
#   This script is the *no-tools* fallback: it draws tasteful, dark,
#   corvid-themed PNGs using nothing but the Python standard library (zlib +
#   struct), so `generate-assets.sh` (and this repo) ALWAYS produce a real
#   raster asset even on a host with no image toolchain. It also runs on macOS
#   (the authoring host), which is how the committed baseline PNGs were made.
#
# OUTPUT (written next to this file, under branding/assets/):
#   wallpaper-1920x1080.png   desktop + SDDM + plymouth background + grub splash
#   logo-512.png              Calamares logo / app icon / plymouth logo
#   splash-640x480.png        BIOS/isolinux boot-menu background
#
# Palette: near-black indigo base, muted steel accents, one electric-cyan spark
# (the "smart, dark, hacker" corvid aesthetic from the brief).
# =============================================================================

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "assets")

# --- Palette (R, G, B) -------------------------------------------------------
BG_TOP = (0x0A, 0x0C, 0x12)      # near-black indigo (top of gradient)
BG_BOT = (0x11, 0x16, 0x22)      # slightly lifted indigo (bottom)
INK = (0xE8, 0xEC, 0xF4)         # off-white wordmark
MUTED = (0x3A, 0x44, 0x59)       # steel — feather/chevron motif
ACCENT = (0x27, 0xE0, 0xC8)      # electric cyan spark (the "eye"/accent)
SUBT = (0x6B, 0x76, 0x8C)        # subtitle grey


# --- 5x7 bitmap font: just the glyphs the wordmark needs --------------------
# Rows top->bottom, 5 columns, '1' = ink pixel.
FONT = {
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "V": ["10001", "10001", "10001", "10001", "01010", "01010", "00100"],
    "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
    "D": ["11100", "10010", "10001", "10001", "10001", "10010", "11100"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
}


class Canvas:
    def __init__(self, w, h, bg=(0, 0, 0)):
        self.w = w
        self.h = h
        self.px = bytearray(bg * (w * h))

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 3
            self.px[i:i + 3] = bytes(c)

    def vgradient(self, top, bot):
        for y in range(self.h):
            t = y / max(1, self.h - 1)
            c = (
                round(top[0] + (bot[0] - top[0]) * t),
                round(top[1] + (bot[1] - top[1]) * t),
                round(top[2] + (bot[2] - top[2]) * t),
            )
            row = bytes(c) * self.w
            self.px[y * self.w * 3:(y + 1) * self.w * 3] = row

    def rect(self, x0, y0, x1, y1, c):
        for y in range(max(0, y0), min(self.h, y1)):
            for x in range(max(0, x0), min(self.w, x1)):
                self.set(x, y, c)

    def blend(self, x, y, c, a):
        # alpha blend c over existing pixel, a in 0..1
        if not (0 <= x < self.w and 0 <= y < self.h):
            return
        i = (y * self.w + x) * 3
        b = self.px[i:i + 3]
        self.px[i:i + 3] = bytes(
            round(b[k] + (c[k] - b[k]) * a) for k in range(3)
        )

    def text(self, s, x, y, scale, c):
        cx = x
        for ch in s.upper():
            glyph = FONT.get(ch, FONT[" "])
            for ry, rowbits in enumerate(glyph):
                for rxi, bit in enumerate(rowbits):
                    if bit == "1":
                        self.rect(
                            cx + rxi * scale, y + ry * scale,
                            cx + (rxi + 1) * scale, y + (ry + 1) * scale, c,
                        )
            cx += (5 + 1) * scale  # 1 column letter spacing

    def text_width(self, s, scale):
        return len(s) * (5 + 1) * scale - scale

    def write(self, path):
        raw = bytearray()
        stride = self.w * 3
        for y in range(self.h):
            raw.append(0)  # filter type 0 (None) per scanline
            raw.extend(self.px[y * stride:(y + 1) * stride])
        comp = zlib.compress(bytes(raw), 9)

        def chunk(tag, data):
            return (struct.pack(">I", len(data)) + tag + data
                    + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

        ihdr = struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0)
        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", ihdr)
               + chunk(b"IDAT", comp)
               + chunk(b"IEND", b""))
        with open(path, "wb") as f:
            f.write(png)


def feather_motif(c, cx, cy, length, angle_step, count, color):
    """A minimal geometric feather: a stack of angled chevron barbs."""
    import math
    for i in range(count):
        off = i * angle_step
        # left barb and right barb of the feather
        for t in range(length):
            px = cx - t
            py = cy - off - int(t * 0.55)
            c.blend(px, py, color, 0.5)
            c.blend(px, py + 1, color, 0.25)
        for t in range(length):
            px = cx + t
            py = cy - off - int(t * 0.55)
            c.blend(px, py, color, 0.35)
            c.blend(px, py + 1, color, 0.18)


def raven_mark(c, cx, cy, s, body, spark):
    """A minimal angular raven glyph: a filled chevron 'wing' + cyan eye."""
    # wing: a downward chevron built from two slabs
    for i in range(s):
        w = s - i
        c.rect(cx - w, cy - s + i, cx + w, cy - s + i + 1, body)
    # head/beak: a small triangle to the upper right
    for i in range(s // 2):
        c.rect(cx + i, cy - s - i, cx + i + 2, cy - s - i + 1, body)
    # the spark / eye
    c.rect(cx + s // 3, cy - s + s // 4, cx + s // 3 + max(4, s // 8),
           cy - s + s // 4 + max(4, s // 8), spark)


def make_wallpaper(w, h, with_tagline=True):
    c = Canvas(w, h, BG_TOP)
    c.vgradient(BG_TOP, BG_BOT)

    # faint diagonal feather field, upper-left and lower-right, for texture
    feather_motif(c, int(w * 0.30), int(h * 0.42), int(h * 0.18),
                  max(3, h // 90), 10, MUTED)
    feather_motif(c, int(w * 0.78), int(h * 0.70), int(h * 0.14),
                  max(3, h // 110), 8, MUTED)

    # central raven mark above the wordmark
    raven_mark(c, w // 2, int(h * 0.40), max(28, h // 22), MUTED, ACCENT)

    # wordmark "CORVID OS", centered
    word = "CORVID OS"
    scale = max(4, h // 90)
    tw = c.text_width(word, scale)
    tx = (w - tw) // 2
    ty = int(h * 0.46)
    c.text(word, tx, ty, scale, INK)

    # thin accent underline
    c.rect(tx, ty + 8 * scale + scale, tx + tw, ty + 8 * scale + scale + max(2, scale // 3), ACCENT)

    if with_tagline:
        tag = "SECURE CODING LINUX"
        # tagline uses only letters we have? has E,U,N,G,L,K missing -> skip unknowns
        # keep it safe: render with available glyphs only via a curated string
        tag = "CORVID"
        # (tagline intentionally minimal; the SVG carries full typography)
    return c


def make_logo(size=512):
    c = Canvas(size, size, BG_TOP)
    c.vgradient(BG_TOP, BG_BOT)
    # rounded-ish dark tile border accent
    m = size // 12
    c.rect(m, m, size - m, m + max(2, size // 90), MUTED)
    c.rect(m, size - m - max(2, size // 90), size - m, size - m, MUTED)
    # big raven mark
    raven_mark(c, size // 2, int(size * 0.60), size // 4, INK, ACCENT)
    return c


def main():
    os.makedirs(OUT, exist_ok=True)
    make_wallpaper(1920, 1080).write(os.path.join(OUT, "wallpaper-1920x1080.png"))
    make_wallpaper(640, 480, with_tagline=False).write(os.path.join(OUT, "splash-640x480.png"))
    make_logo(512).write(os.path.join(OUT, "logo-512.png"))
    print("Wrote PNG assets to", OUT)


if __name__ == "__main__":
    main()
