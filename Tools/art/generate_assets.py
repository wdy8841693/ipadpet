#!/usr/bin/env python3
"""鲸鱼娘 DSH 宠物 —— 程序化素材生成器（原创矢量绘制，无第三方版权素材）。

输出到 WhalePet/Resources.xcassets 下的 imageset：
  whale_body / whale_tail / whale_fin / whale_hair / whale_spout
  whale_face_normal / whale_face_happy / whale_face_sleep / whale_face_sad
  whale_blush / fx_heart / fx_fish / bg_gradient / AppIcon

设计：Q 版蓝鲸娘 —— 圆滚滚的蓝白鲸身 + 头顶喷水鳍冠（"头发"）+ 大眼腮红。
所有部件独立 PNG，运行时由 SpriteKit 分层拼装并做程序化动画。
4x 超采样后缩到目标尺寸，保证 Retina 边缘平滑。

用法: python3 Tools/art/generate_assets.py [--out WhalePet/Resources.xcassets]
依赖: Pillow >= 9
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SS = 4  # 超采样倍数

# 调色板
DEEP_BLUE = (58, 108, 168)      # 鲸背
MID_BLUE = (92, 148, 205)       # 鲸身主色
LIGHT_BLUE = (140, 185, 230)    # 高光
BELLY = (235, 244, 250)         # 肚皮白
OUTLINE = (36, 66, 104)         # 描边
CHEEK = (255, 150, 160)         # 腮红
EYE = (30, 44, 66)              # 眼睛
MOUTH = (60, 80, 110)
HAIR_TEAL = (72, 190, 200)      # 鳍冠青
SPOUT = (170, 220, 250)


def canvas(w: int, h: int) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def finish(img: Image.Image, w: int, h: int) -> Image.Image:
    return img.resize((w, h), Image.LANCZOS)


def ellipse(d, cx, cy, rx, ry, fill, outline=None, ow=3):
    d.ellipse([(cx - rx) * SS, (cy - ry) * SS, (cx + rx) * SS, (cy + ry) * SS],
              fill=fill, outline=outline, width=ow * SS)


def poly(d, pts, fill, outline=None, ow=3):
    d.polygon([(x * SS, y * SS) for x, y in pts], fill=fill, outline=outline)
    if outline:
        d.line([(x * SS, y * SS) for x, y in pts] + [(pts[0][0] * SS, pts[0][1] * SS)],
               fill=outline, width=ow * SS, joint="curve")


# ---------------------------------------------------------------- 身体
def make_body() -> Image.Image:
    """圆滚鲸身：上蓝下白，带渐变高光。260x220"""
    w, h = 260, 220
    img, d = canvas(w, h)
    cx, cy, rx, ry = 130, 118, 112, 96
    # 主体
    ellipse(d, cx, cy, rx, ry, MID_BLUE, OUTLINE, 4)
    # 肚皮（下半白，用裁剪椭圆）
    belly = Image.new("RGBA", img.size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(belly)
    ellipse(bd, cx, cy + 34, rx - 14, ry - 22, BELLY)
    mask = Image.new("L", img.size, 0)
    md = ImageDraw.Draw(mask)
    md.ellipse([(cx - rx + 4) * SS, (cy - ry + 4) * SS, (cx + rx - 4) * SS, (cy + ry - 4) * SS], fill=255)
    img.paste(belly, (0, 0), Image.composite(belly.split()[3], Image.new("L", img.size, 0), mask))
    d = ImageDraw.Draw(img)
    # 背部高光
    ellipse(d, cx - 34, cy - 44, 44, 22, LIGHT_BLUE + (150,))
    # 鲸须纹（肚皮竖线）
    for i in range(-2, 3):
        x = cx + i * 22
        d.line([(x * SS, (cy + 30) * SS), (x * SS, (cy + 84) * SS)],
               fill=(190, 210, 228, 200), width=2 * SS)
    return finish(img, w, h)


# ---------------------------------------------------------------- 尾巴
def make_tail() -> Image.Image:
    """双叶尾鳍，锚点在顶部（尾根）。160x110"""
    w, h = 160, 110
    img, d = canvas(w, h)
    # 尾柄
    poly(d, [(72, 0), (88, 0), (94, 42), (66, 42)], MID_BLUE, OUTLINE, 3)
    # 左叶
    poly(d, [(80, 38), (18, 58), (6, 96), (44, 88), (78, 62)], DEEP_BLUE, OUTLINE, 3)
    # 右叶
    poly(d, [(80, 38), (142, 58), (154, 96), (116, 88), (82, 62)], DEEP_BLUE, OUTLINE, 3)
    # 中凹
    ellipse(d, 80, 52, 10, 8, MID_BLUE)
    return finish(img, w, h)


# ---------------------------------------------------------------- 侧鳍
def make_fin() -> Image.Image:
    """单侧胸鳍（左向，根部在右；运行时镜像出另一侧）。90x60"""
    w, h = 90, 60
    img, d = canvas(w, h)
    # 圆润叶形：根(84,18) → 尖(10,44)
    poly(d, [(84, 10), (46, 12), (14, 30), (8, 46), (30, 52), (62, 44), (84, 30)],
         DEEP_BLUE, OUTLINE, 3)
    poly(d, [(78, 16), (48, 18), (24, 32), (20, 42), (38, 46), (64, 38), (78, 28)],
         MID_BLUE)
    return finish(img, w, h)


# ---------------------------------------------------------------- 鳍冠头发
def make_hair() -> Image.Image:
    """头顶三撮青色鳍冠 = 鲸鱼娘的呆毛。120x70"""
    w, h = 120, 70
    img, d = canvas(w, h)
    poly(d, [(60, 66), (34, 30), (44, 6), (58, 34)], HAIR_TEAL, OUTLINE, 3)
    poly(d, [(60, 66), (60, 2), (76, 10), (70, 40)], HAIR_TEAL, OUTLINE, 3)
    poly(d, [(62, 66), (88, 26), (98, 44), (76, 58)], HAIR_TEAL, OUTLINE, 3)
    return finish(img, w, h)


# ---------------------------------------------------------------- 喷水
def make_spout() -> Image.Image:
    """喷水柱 + 水花。80x110，锚点底部。"""
    w, h = 80, 110
    img, d = canvas(w, h)
    poly(d, [(34, 110), (46, 110), (44, 40), (36, 40)], SPOUT + (220,))
    for cx, cy, r in [(40, 26, 12), (22, 40, 8), (58, 40, 8), (12, 56, 5), (68, 56, 5)]:
        ellipse(d, cx, cy, r, r, SPOUT + (200,))
    return finish(img, w, h)


# ---------------------------------------------------------------- 表情
def _face_base(w=200, h=120):
    return canvas(w, h)


def make_face_normal() -> Image.Image:
    w, h = 200, 120
    img, d = _face_base(w, h)
    # 大眼
    for ex in (62, 138):
        ellipse(d, ex, 52, 15, 19, EYE)
        ellipse(d, ex - 5, 45, 5, 6, (255, 255, 255, 235))
        ellipse(d, ex + 6, 58, 2.5, 3, (255, 255, 255, 160))
    # ω 嘴
    d.arc([(86) * SS, (78) * SS, (100) * SS, (92) * SS], 0, 180, fill=MOUTH, width=3 * SS)
    d.arc([(100) * SS, (78) * SS, (114) * SS, (92) * SS], 0, 180, fill=MOUTH, width=3 * SS)
    return finish(img, w, h)


def make_face_happy() -> Image.Image:
    w, h = 200, 120
    img, d = _face_base(w, h)
    # ^ ^ 弯月眼
    for ex in (62, 138):
        d.arc([(ex - 16) * SS, (40) * SS, (ex + 16) * SS, (68) * SS],
              200, 340, fill=EYE, width=5 * SS)
    # 张嘴笑
    d.pieslice([(84) * SS, (72) * SS, (116) * SS, (100) * SS], 0, 180, fill=(120, 60, 80))
    d.arc([(84) * SS, (72) * SS, (116) * SS, (100) * SS], 0, 180, fill=MOUTH, width=3 * SS)
    return finish(img, w, h)


def make_face_sleep() -> Image.Image:
    w, h = 200, 120
    img, d = _face_base(w, h)
    for ex in (62, 138):
        d.arc([(ex - 15) * SS, (44) * SS, (ex + 15) * SS, (66) * SS],
              20, 160, fill=EYE, width=4 * SS)
    # 小 o 嘴
    ellipse(d, 100, 86, 6, 7, MOUTH)
    return finish(img, w, h)


def make_face_sad() -> Image.Image:
    w, h = 200, 120
    img, d = _face_base(w, h)
    for ex in (62, 138):
        ellipse(d, ex, 56, 13, 16, EYE)
        ellipse(d, ex - 4, 50, 4, 5, (255, 255, 255, 220))
        # 下垂眉
        sx = ex - 16 if ex < 100 else ex + 16
        ex2 = ex + 10 if ex < 100 else ex - 10
        d.line([(sx * SS, 30 * SS), (ex2 * SS, 38 * SS)], fill=EYE, width=3 * SS)
    # 波浪委屈嘴
    d.arc([(88) * SS, (84) * SS, (112) * SS, (100) * SS], 180, 360, fill=MOUTH, width=3 * SS)
    # 一滴泪
    ellipse(d, 152, 74, 4, 6, (150, 210, 250, 220))
    return finish(img, w, h)


def make_blush() -> Image.Image:
    w, h = 200, 120
    img, d = _face_base(w, h)
    for cx in (40, 160):
        ellipse(d, cx, 78, 17, 10, CHEEK + (140,))
    img = img.filter(ImageFilter.GaussianBlur(SS * 1.2))
    return finish(img, w, h)


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
    # 顶部光柱：画在独立图层上再合成，避免 ImageDraw 直接覆盖底色
    rays = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rays)
    for x0, spread, alpha in [(120, 90, 30), (330, 130, 24), (560, 80, 28)]:
        rd.polygon([(x0, 0), (x0 + spread, 0), (x0 + spread + 160, h), (x0 - 60, h)],
                   fill=(120, 190, 240, alpha))
    rays = rays.filter(ImageFilter.GaussianBlur(10))
    img.alpha_composite(rays)
    # 远处浮游光点
    d = ImageDraw.Draw(img, "RGBA")
    import random
    rnd = random.Random(42)
    for _ in range(60):
        x, y = rnd.randint(0, w), rnd.randint(0, h)
        r = rnd.randint(1, 3)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(160, 220, 255, rnd.randint(30, 90)))
    return img


def make_appicon() -> Image.Image:
    """1024x1024 App 图标：圆角矩形深海底 + 鲸鱼娘脸。"""
    s = 1024
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=224, fill=(14, 46, 88))
    # 光晕
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([112, 96, 912, 896], fill=(30, 90, 150, 255))
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    img.alpha_composite(glow)
    d = ImageDraw.Draw(img)
    # 身体
    ellipse(d, 512, 560, 330, 290, MID_BLUE, OUTLINE, 10)
    ellipse(d, 512, 660, 280, 200, BELLY)
    # 鳍冠
    hair = make_hair().resize((360, 210), Image.LANCZOS)
    img.alpha_composite(hair, (332, 130))
    # 脸
    face = make_face_normal().resize((600, 360), Image.LANCZOS)
    img.alpha_composite(face, (212, 400))
    blush = make_blush().resize((600, 360), Image.LANCZOS)
    img.alpha_composite(blush, (212, 400))
    # 尾巴尖露出右下
    tail = make_tail().resize((300, 206), Image.LANCZOS)
    img.alpha_composite(tail, (700, 760))
    return img


# ---------------------------------------------------------------- 输出
IMAGESETS = {
    "whale_body": make_body,
    "whale_tail": make_tail,
    "whale_fin": make_fin,
    "whale_hair": make_hair,
    "whale_spout": make_spout,
    "whale_face_normal": make_face_normal,
    "whale_face_happy": make_face_happy,
    "whale_face_sleep": make_face_sleep,
    "whale_face_sad": make_face_sad,
    "whale_blush": make_blush,
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

    # AppIcon.appiconset（iPad 全尺寸）
    icon_dir = root / "AppIcon.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    icon = make_appicon()
    icon.save(icon_dir / "icon_1024.png")
    sizes = [
        ("20", "1x", 20), ("20", "2x", 40), ("29", "1x", 29), ("29", "2x", 58),
        ("40", "1x", 40), ("40", "2x", 80), ("76", "1x", 76), ("76", "2x", 152),
        ("83.5", "2x", 167),
    ]
    images = []
    for pt, scale, px in sizes:
        fn = f"icon_{px}.png"
        icon.resize((px, px), Image.LANCZOS).save(icon_dir / fn)
        images.append({"size": f"{pt}x{pt}", "idiom": "ipad", "filename": fn, "scale": scale})
    images.append({"size": "1024x1024", "idiom": "ios-marketing",
                   "filename": "icon_1024.png", "scale": "1x"})
    (icon_dir / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print("  ✓ AppIcon (ipad 全套)")
    print(f"完成 → {root}")


if __name__ == "__main__":
    main()