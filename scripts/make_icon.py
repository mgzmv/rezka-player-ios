#!/usr/bin/env python3
"""Generates the 1024x1024 app icon (pure Python, no dependencies)."""
import struct
import sys
import zlib

S = 1024
BG = (52, 40, 140)
FG = (255, 255, 255)
CX = CY = 512
R_OUT2, R_IN2 = 322 * 322, 286 * 286


def chunk(tag: bytes, data: bytes) -> bytes:
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def main(out: str) -> None:
    raw = bytearray()
    bg = bytes(BG)
    fg = bytes(FG)
    for y in range(S):
        raw.append(0)  # filter type: none
        dy = y - CY
        row = bytearray()
        for x in range(S):
            dx = x - CX
            d2 = dx * dx + dy * dy
            on = R_IN2 <= d2 <= R_OUT2
            if not on and 410 <= x <= 790:
                half = 212 * (790 - x) / 380
                on = abs(dy) <= half
            row += fg if on else bg
        raw += row
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(out, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    main(sys.argv[1])
