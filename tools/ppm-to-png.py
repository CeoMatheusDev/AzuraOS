#!/usr/bin/env python3
"""Convert a binary PPM (P6) screenshot into a PNG file.

Usage: ppm-to-png.py <input.ppm> <output.png>

The conversion is implemented with the standard library only (zlib + struct),
so the repository does not need an image library to produce viewable
screenshots of the boot process.
"""

import struct
import sys
import zlib


def read_ppm(path: str) -> tuple[int, int, bytes]:
    with open(path, "rb") as handle:
        data = handle.read()

    if not data.startswith(b"P6"):
        raise ValueError("only the binary PPM format (P6) is supported")

    # Parse the header: magic, width, height, maxval, then a single
    # whitespace character before the pixel data.
    fields = []
    index = 2
    while len(fields) < 3:
        while index < len(data) and data[index : index + 1].isspace():
            index += 1
        if data[index : index + 1] == b"#":
            while index < len(data) and data[index] != 0x0A:
                index += 1
            continue
        start = index
        while index < len(data) and not data[index : index + 1].isspace():
            index += 1
        fields.append(int(data[start:index]))
    index += 1  # single whitespace separator before the pixels

    width, height, maxval = fields
    if maxval != 255:
        raise ValueError(f"unsupported maxval {maxval}, expected 255")

    pixels = data[index : index + width * height * 3]
    if len(pixels) != width * height * 3:
        raise ValueError("truncated pixel data")
    return width, height, pixels


def write_png(path: str, width: int, height: int, pixels: bytes) -> None:
    raw = bytearray()
    stride = width * 3
    for row in range(height):
        raw.append(0)  # filter type 0 (None)
        raw.extend(pixels[row * stride : (row + 1) * stride])

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", header))
        handle.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        handle.write(chunk(b"IEND", b""))


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: ppm-to-png.py <input.ppm> <output.png>", file=sys.stderr)
        return 2

    try:
        width, height, pixels = read_ppm(sys.argv[1])
        write_png(sys.argv[2], width, height, pixels)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"PNG written: {sys.argv[2]} ({width}x{height})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
