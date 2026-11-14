#!/usr/bin/env python3
"""鲸鱼娘 DSH 宠物 —— 环境/特效素材生成器（原创矢量绘制）。

角色立绘已改用开源项目 dsh-whale-musume（MIT）的成品素材，
见 import_upstream.py；本脚本只负责背景与特效小件：
  bg_gradient（深海渐变）/ fx_heart（爱心）/ fx_fish（小鱼干）

历史版本曾包含程序化角色部件，现已移除（git 历史可查）。

用法: python3 Tools/art/generate_assets.py [--out WhalePet/Resources.xcassets]
依赖: Pillow >= 9
"""
from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SS = 4  # 超采样倍数




def canvas(w: int, h: int):
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def finish(img: Image.Image, w: int, h: int) -> Image.Image:
    return img.resize((w, h), Image.LANCZOS)


def ellipse(d, cx, cy, rx, ry, fill, outline=None, ow=3):
    d.ellipse([(cx - rx) * SS, (cy - ry) * SS, (cx + rx) * SS, (cy + ry) * SS],
              fill=fill, outline=outline, width=ow * SS)


def poly(d, pts, fill, outline=None, ow=3):
    p = [(x * SS, y * SS) for x, y in pts]
    d.polygon(p, fill=fill)
    if outline:
        d.line(p + [p[0]], fill=outline, width=ow * SS, joint="curve")


def rrect(d, x0, y0, x1, y1, r, fill, outline=None, ow=3):
    d.rounded_rectangle([x0 * SS, y0 * SS, x1 * SS, y1 * SS], radius=r * SS,
                        fill=fill, outline=outline, width=ow * SS)


# ---------------------------------------------------------------- 背景
def make_bg_gradient() -> Image.Image:
    """深海纵向渐变 + 光斑。768x1024（拉伸到任意屏幕）。"""
    w, h = 768, 1024
    img = Image.new("RGBA", (w, h))
    top = (16, 60, 110)
    mid = (10, 40, 82)
    bot = (6, 22, 48)
    px = img.load()
    for y in range(h):
        t = y / h
        if t < 0.5:
            k = t / 0.5
            c = tuple(int(top[i] + (mid[i] - top[i]) * k) for i in range(3))
        else:
            k = (t - 0.5) / 0.5
            c = tuple(int(mid[i] + (bot[i] - mid[i]) * k) for i in range(3))
        for x in range(w):
            px[x, y] = c + (255,)
    rays = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rays)
    for x0, spread, alpha in [(120, 90, 30), (330, 130, 24), (560, 80, 28)]:
        rd.polygon([(x0, 0), (x0 + spread, 0), (x0 + spread + 160, h), (x0 - 60, h)],
                   fill=(120, 190, 240, alpha))
    rays = rays.filter(ImageFilter.GaussianBlur(10))
    img.alpha_composite(rays)
    d = ImageDraw.Draw(img, "RGBA")
    rnd = random.Random(42)
    for _ in range(60):
        x, y = rnd.randint(0, w), rnd.randint(0, h)
        r = rnd.randint(1, 3)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(160, 220, 255, rnd.randint(30, 90)))
    return img


# ---------------------------------------------------------------- 特效
def make_heart() -> Image.Image:
    w, h = 48, 44
    img, d = canvas(w, h)
    c = (255, 105, 135)
    ellipse(d, 15, 15, 11, 11, c)
    ellipse(d, 33, 15, 11, 11, c)
    poly(d, [(5, 20), (43, 20), (24, 42)], c)
    ellipse(d, 12, 11, 4, 4, (255, 190, 205, 230))
    return finish(img, w, h)


def make_fish() -> Image.Image:
    """小鱼干。64x36"""
    w, h = 64, 36
    img, d = canvas(w, h)
    body_c = (250, 200, 120)
    ellipse(d, 26, 18, 20, 11, body_c, (180, 130, 60), 2)
    poly(d, [(44, 18), (60, 8), (60, 28)], body_c, (180, 130, 60), 2)
    ellipse(d, 16, 15, 2.5, 2.5, (60, 50, 40))
    d.arc([(20) * SS, (12) * SS, (34) * SS, (24) * SS], 300, 60, fill=(180, 130, 60), width=2 * SS)
    return finish(img, w, h)


# ---------------------------------------------------------------- 输出
IMAGESETS = {
    "fx_heart": make_heart,
    "fx_fish": make_fish,
    "bg_gradient": make_bg_gradient,
}


def write_imageset(root: Path, name: str, img: Image.Image):
    d = root / f"{name}.imageset"
    d.mkdir(parents=True, exist_ok=True)
    fname = f"{name}.png"
    img.save(d / fname)
    contents = {
        "images": [
            {"idiom": "universal", "filename": fname, "scale": "1x"},
            {"idiom": "universal", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (d / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="WhalePet/Resources.xcassets")
    args = ap.parse_args()
    root = Path(args.out)
    root.mkdir(parents=True, exist_ok=True)
    (root / "Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    for name, fn in IMAGESETS.items():
        write_imageset(root, name, fn())
        print(f"  ✓ {name}")
    print(f"完成 → {root}（角色立绘请用 import_upstream.py 导入）")


if __name__ == "__main__":
    main()