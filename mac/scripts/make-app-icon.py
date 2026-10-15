#!/usr/bin/env python3
"""Draw Battery SOS AppIcon.icns: bold red battery and SOS mark on a dark field."""
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "AppIcon.icns"

# iconutil OSTypes. Same pixel buffer is reused when two slots share a size.
SLOTS = (
    (b"icp4", 16),
    (b"ic11", 32),
    (b"icp5", 32),
    (b"ic12", 64),
    (b"icp6", 64),
    (b"ic07", 128),
    (b"ic13", 256),
    (b"ic08", 256),
    (b"ic14", 512),
    (b"ic09", 512),
    (b"ic10", 1024),
)

BG = (20, 12, 16)
RED = (255, 42, 48)
WHITE = (255, 255, 255)

# 5x7 SOS, kept for sizes where the letters survive.
GLYPHS = {
    "S": (
        "#####",
        "#....",
        "#....",
        "#####",
        "....#",
        "....#",
        "#####",
    ),
    "O": (
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    ),
}


def png(width, height, rgba):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def in_round_rect(px, py, x, y, w, h, r):
    if px < x or py < y or px >= x + w or py >= y + h:
        return False
    dx = (x + r) - px if px < x + r else (px - (x + w - r) if px > x + w - r else 0)
    dy = (y + r) - py if py < y + r else (py - (y + h - r) if py > y + h - r else 0)
    if dx == 0 or dy == 0:
        return True
    return dx * dx + dy * dy <= r * r


def cover(samples, px, py, shape):
    hit = 0
    for sy in range(samples):
        for sx in range(samples):
            if shape(px + (sx + 0.5) / samples, py + (sy + 0.5) / samples):
                hit += 1
    return hit / (samples * samples)


def blend(dst, src, alpha):
    if alpha <= 0:
        return dst
    if alpha >= 1:
        return src
    return tuple(int(dst[i] + (src[i] - dst[i]) * alpha) for i in range(3))


def draw(size):
    samples = 2
    buf = bytearray(size * size * 4)
    for i in range(size * size):
        buf[i * 4:i * 4 + 4] = bytes((*BG, 255))

    def put(x, y, color, alpha):
        if x < 0 or y < 0 or x >= size or y >= size or alpha <= 0:
            return
        i = (y * size + x) * 4
        mixed = blend(buf[i:i + 3], color, min(1, alpha))
        buf[i:i + 3] = bytes(mixed)

    def paint(rect, color):
        x, y, w, h, r = rect
        x0, y0 = int(x) - 1, int(y) - 1
        x1, y1 = int(x + w) + 2, int(y + h) + 2
        for py in range(max(0, y0), min(size, y1)):
            for px in range(max(0, x0), min(size, x1)):
                alpha = cover(samples, px, py, lambda fx, fy: in_round_rect(fx, fy, x, y, w, h, r))
                put(px, py, color, alpha)

    # Stay inside the squircle mask. SOS only when the letters have room.
    show_text = size >= 128
    if show_text:
        cap_y, cap_h = size * 0.14, max(size * 0.045, 1)
        body_y, body_h = size * 0.19, size * 0.42
    else:
        cap_y, cap_h = size * 0.16, max(size * 0.07, 1)
        body_y, body_h = size * 0.24, size * 0.56
    body_x, body_w = size * 0.27, size * 0.46
    radius = max(size * 0.07, 1)
    cap_w = size * 0.18
    paint((body_x, body_y, body_w, body_h, radius), RED)
    paint((size * 0.5 - cap_w / 2, cap_y, cap_w, cap_h, max(cap_h * 0.35, 0.5)), RED)

    bang_w = max(size * (0.14 if size < 64 else 0.065), 2 if size >= 16 else 1)
    bang_h = body_h * (0.46 if size < 64 else 0.40)
    bang_x = size * 0.5 - bang_w / 2
    bang_y = body_y + body_h * 0.14
    gap = max(bang_w * 0.35, 1)
    dot = bang_w * 0.95
    paint((bang_x, bang_y, bang_w, bang_h, bang_w / 2), WHITE)
    paint((size * 0.5 - dot / 2, bang_y + bang_h + gap, dot, dot, dot / 2), WHITE)

    if show_text:
        unit = size * 0.034
        gap_x = unit * 0.7
        text = "SOS"
        block_w = len(text) * 5 * unit + (len(text) - 1) * gap_x
        origin_x = (size - block_w) / 2
        origin_y = body_y + body_h + size * 0.035
        for index, char in enumerate(text):
            glyph = GLYPHS[char]
            gx = origin_x + index * (5 * unit + gap_x)
            for row, bits in enumerate(glyph):
                for col, bit in enumerate(bits):
                    if bit != "#":
                        continue
                    # Solid cells, no gap, so the letters survive the mask.
                    x0 = int(round(gx + col * unit))
                    y0 = int(round(origin_y + row * unit))
                    x1 = int(round(gx + (col + 1) * unit))
                    y1 = int(round(origin_y + (row + 1) * unit))
                    for py in range(y0, max(y0 + 1, y1)):
                        for px in range(x0, max(x0 + 1, x1)):
                            put(px, py, WHITE, 1)
    return png(size, size, bytes(buf))


def icns(images):
    chunks = []
    cache = {}
    for ostype, size in SLOTS:
        if size not in cache:
            cache[size] = images[size]
        data = cache[size]
        chunks.append(ostype + struct.pack(">I", 8 + len(data)) + data)
    body = b"".join(chunks)
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def main():
    sizes = sorted({size for _, size in SLOTS})
    images = {size: draw(size) for size in sizes}
    payload = icns(images)
    OUT.write_bytes(payload)
    print(f"wrote {OUT} ({len(payload)} bytes)")


if __name__ == "__main__":
    main()
