#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一张 1024×1024 的 PNG 图标切成 Android 各密度 mipmap（纯标准库，不依赖 Pillow）。

用法：
    python tools/make_icons.py <源图.png> <res目录>

说明：这里只实现了 8bit RGBA、非隔行的 PNG（本项目图标就是这种），
用 box 平均做降采样，质量对图标来说足够。
"""
import os
import struct
import sys
import zlib

SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG")
    pos, idat = 8, b""
    w = h = bd = ct = None
    while pos < len(data):
        (ln,) = struct.unpack(">I", data[pos:pos + 4])
        typ = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            w, h, bd, ct, _comp, _filt, inter = struct.unpack(">IIBBBBB", chunk)
            if bd != 8 or ct != 6 or inter != 0:
                raise ValueError("只支持 8bit RGBA 非隔行 PNG")
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
    raw = zlib.decompress(idat)
    bpp = 4
    stride = w * bpp
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if f == 1:      # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif f == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:    # Average
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif f == 4:    # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, out


def downscale(w, h, rgba, size):
    out = bytearray(size * size * 4)
    for y in range(size):
        y0 = y * h // size
        y1 = max(y0 + 1, (y + 1) * h // size)
        for x in range(size):
            x0 = x * w // size
            x1 = max(x0 + 1, (x + 1) * w // size)
            r = g = b = a = 0
            n = 0
            for yy in range(y0, y1):
                base = yy * w * 4
                for xx in range(x0, x1):
                    i = base + xx * 4
                    al = rgba[i + 3]
                    r += rgba[i] * al
                    g += rgba[i + 1] * al
                    b += rgba[i + 2] * al
                    a += al
                    n += 1
            o = (y * size + x) * 4
            if a > 0:
                out[o] = r // a
                out[o + 1] = g // a
                out[o + 2] = b // a
                out[o + 3] = a // n
            else:
                out[o:o + 4] = b"\x00\x00\x00\x00"
    return out


def write_png(path, size, rgba):
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        raw += rgba[y * size * 4:(y + 1) * size * 4]

    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(png)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src, res_dir = sys.argv[1], sys.argv[2]
    w, h, rgba = read_png(src)
    for folder, size in SIZES.items():
        out = downscale(w, h, rgba, size)
        dst = os.path.join(res_dir, folder, "ic_launcher.png")
        write_png(dst, size, out)
        print("生成", dst, size, "x", size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
