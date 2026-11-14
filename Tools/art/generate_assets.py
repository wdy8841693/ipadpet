#!/usr/bin/env python3
"""鲸鱼娘 DSH 宠物 —— 程序化素材生成器（原创矢量绘制，无第三方版权素材）。

角色设定：鲸鱼娘 = 蓝鲸主题的 Q 版人形少女（chibi girl），不是鲸鱼本体：
  - 蓝色长发 + 呆毛，头顶小喷水孔偶尔喷水
  - 两侧鲸鳍发饰（代替兽耳）
  - 大白眼珠 anime 脸 + 腮红
  - 白色水手领连衣裙（蓝领巾）
  - 人手人腿 + 小皮鞋
  - 身后一条蓝鲸尾（尾巴是鲸元素，身体是人）

输出到 WhalePet/Resources.xcassets 下的 imageset：
  whale_hair_back / whale_body(连衣裙+躯干) / whale_head(脸底+发) /
  whale_tail / whale_fin(鳍发饰) / whale_arm / whale_leg /
  whale_face_normal / whale_face_happy / whale_face_sleep / whale_face_sad /
  whale_blush / whale_spout / fx_heart / fx_fish / bg_gradient / AppIcon

所有部件独立 PNG，运行时由 SpriteKit 分层拼装并做程序化动画。
4x 超采样后缩到目标尺寸，保证 Retina 边缘平滑。

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

# 调色板
HAIR_BLUE = (86, 140, 200)       # 蓝发主色
HAIR_DARK = (58, 104, 162)       # 发阴影
HAIR_LIGHT = (140, 185, 232)     # 发高光
OUTLINE = (40, 62, 96)           # 描边
SKIN = (255, 232, 214)           # 皮肤
SKIN_SHADE = (244, 208, 186)
DRESS_WHITE = (248, 250, 253)    # 连衣裙白
DRESS_SHADE = (222, 232, 244)
NAVY = (52, 84, 138)             # 水手领/领巾深蓝
WHALE_BLUE = (72, 122, 182)      # 鲸尾/鳍饰
WHALE_BELLY = (214, 232, 246)
CHEEK = (255, 150, 160)
EYE_IRIS = (64, 120, 190)        # 蓝瞳
EYE_DARK = (28, 44, 72)
MOUTH = (150, 80, 90)
SPOUT = (170, 220, 250)
SHOE = (62, 92, 140)


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


# ---------------------------------------------------------------- 后发
def make_hair_back() -> Image.Image:
    """蓝色长发（披在身后，下摆波浪）。220x240，锚点中心。"""
    w, h = 220, 240
    img, d = canvas(w, h)
    # 主体长发轮廓：上圆下波浪
    pts = [(110, 6), (58, 22), (30, 70), (24, 130), (30, 186),
           (44, 224), (60, 206), (76, 232), (94, 210), (110, 236),
           (126, 210), (144, 232), (160, 206), (176, 224),
           (190, 186), (196, 130), (190, 70), (162, 22)]
    poly(d, pts, HAIR_BLUE, OUTLINE, 4)
    # 内侧阴影
    poly(d, [(110, 30), (70, 48), (52, 100), (56, 170), (70, 200),
             (110, 214), (150, 200), (164, 170), (168, 100), (150, 48)],
         HAIR_DARK)
    # 高光缕
    poly(d, [(64, 60), (52, 110), (56, 160), (66, 150), (66, 100)], HAIR_LIGHT)
    poly(d, [(156, 60), (168, 110), (164, 160), (154, 150), (154, 100)], HAIR_LIGHT)
    return finish(img, w, h)


# ---------------------------------------------------------------- 头（脸底+刘海+呆毛）
def make_head() -> Image.Image:
    """头部：圆脸 + 刘海 + 呆毛。180x170，锚点中心。表情贴图另叠。"""
    w, h = 180, 170
    img, d = canvas(w, h)
    cx, cy = 90, 96
    # 后脑头发（比脸大一圈；压低避免盖过呆毛）
    ellipse(d, cx, cy + 2, 76, 66, HAIR_BLUE, OUTLINE, 4)
    # 脸
    ellipse(d, cx, cy + 8, 62, 58, SKIN, OUTLINE, 3)
    # 刘海：锯齿盖住额头上半（整体上移，露出更多脸）
    bangs = [(30, 72), (38, 44), (62, 30), (90, 26), (118, 30), (142, 44), (150, 72),
             (136, 60), (124, 76), (110, 58), (96, 78), (82, 58), (68, 76), (54, 60), (42, 76)]
    poly(d, bangs, HAIR_BLUE, OUTLINE, 3)
    # 刘海高光
    poly(d, [(58, 42), (86, 33), (112, 35), (100, 44), (78, 44)], HAIR_LIGHT)
    # 鬓发两缕
    poly(d, [(30, 74), (24, 118), (36, 132), (44, 100)], HAIR_BLUE, OUTLINE, 3)
    poly(d, [(150, 74), (156, 118), (144, 132), (136, 100)], HAIR_BLUE, OUTLINE, 3)
    # 呆毛（ahoge）
    d.line([(90 * SS, 26 * SS), (82 * SS, 8 * SS), (98 * SS, 2 * SS)],
           fill=OUTLINE, width=5 * SS, joint="curve")
    d.line([(90 * SS, 26 * SS), (83 * SS, 9 * SS), (97 * SS, 4 * SS)],
           fill=HAIR_BLUE, width=3 * SS, joint="curve")
    # 头顶小喷水孔（鲸元素点缀）
    ellipse(d, 118, 30, 5, 3.5, HAIR_DARK, OUTLINE, 2)
    return finish(img, w, h)


# ---------------------------------------------------------------- 躯干+连衣裙
def make_body() -> Image.Image:
    """水手领白色连衣裙 + 脖子。150x150，锚点中心。"""
    w, h = 150, 150
    img, d = canvas(w, h)
    cx = 75
    # 脖子
    rrect(d, cx - 9, 2, cx + 9, 22, 4, SKIN, OUTLINE, 2)
    # 裙子主体：A 字
    dress = [(cx - 26, 20), (cx + 26, 20), (cx + 40, 60), (cx + 52, 118),
             (cx + 44, 132), (cx - 44, 132), (cx - 52, 118), (cx - 40, 60)]
    poly(d, dress, DRESS_WHITE, OUTLINE, 3)
    # 裙摆阴影褶
    for dx in (-30, -10, 10, 30):
        d.line([((cx + dx) * SS, 78 * SS), ((cx + dx * 1.3) * SS, 128 * SS)],
               fill=DRESS_SHADE, width=3 * SS)
    # 裙摆蓝边
    poly(d, [(cx - 50, 116), (cx + 50, 116), (cx + 44, 132), (cx - 44, 132)],
         WHALE_BLUE, OUTLINE, 2)
    # 水手领（大翻领）
    collar = [(cx - 26, 18), (cx + 26, 18), (cx + 34, 44), (cx, 62), (cx - 34, 44)]
    poly(d, collar, NAVY, OUTLINE, 3)
    # 领边白线
    d.line([((cx - 28) * SS, 40 * SS), (cx * SS, 56 * SS), ((cx + 28) * SS, 40 * SS)],
           fill=DRESS_WHITE, width=2 * SS)
    # 领巾结 + 飘带
    ellipse(d, cx, 58, 7, 6, WHALE_BLUE, OUTLINE, 2)
    poly(d, [(cx - 4, 62), (cx - 10, 86), (cx - 2, 82)], WHALE_BLUE, OUTLINE, 2)
    poly(d, [(cx + 4, 62), (cx + 10, 86), (cx + 2, 82)], WHALE_BLUE, OUTLINE, 2)
    return finish(img, w, h)


# ---------------------------------------------------------------- 手臂
def make_arm() -> Image.Image:
    """单只手臂（左向垂下，根部在上；运行时镜像另一侧）。46x86。"""
    w, h = 46, 86
    img, d = canvas(w, h)
    # 袖子（泡泡袖）
    ellipse(d, 28, 16, 15, 14, DRESS_WHITE, OUTLINE, 3)
    # 手臂
    rrect(d, 16, 22, 30, 66, 7, SKIN, OUTLINE, 2)
    # 手
    ellipse(d, 23, 70, 9, 9, SKIN, OUTLINE, 2)
    return finish(img, w, h)


# ---------------------------------------------------------------- 腿
def make_leg() -> Image.Image:
    """单条腿 + 小皮鞋。40x80。"""
    w, h = 40, 80
    img, d = canvas(w, h)
    rrect(d, 13, 0, 27, 56, 7, SKIN, OUTLINE, 2)
    # 白袜口
    rrect(d, 12, 44, 28, 58, 5, DRESS_WHITE, OUTLINE, 2)
    # 鞋
    ellipse(d, 20, 66, 14, 11, SHOE, OUTLINE, 2)
    ellipse(d, 15, 62, 5, 3, (120, 160, 210))
    return finish(img, w, h)


# ---------------------------------------------------------------- 鲸尾
def make_tail() -> Image.Image:
    """身后蓝鲸尾：尾柄 + 双叶尾鳍。170x120，锚点顶部（尾根）。"""
    w, h = 170, 120
    img, d = canvas(w, h)
    # 尾柄（从身体后下方伸出，略弯）
    poly(d, [(76, 0), (94, 0), (102, 40), (86, 52), (70, 40)], WHALE_BLUE, OUTLINE, 3)
    # 左叶
    poly(d, [(85, 44), (24, 60), (8, 102), (50, 92), (84, 66)], WHALE_BLUE, OUTLINE, 3)
    # 右叶
    poly(d, [(85, 44), (146, 60), (162, 102), (120, 92), (86, 66)], WHALE_BLUE, OUTLINE, 3)
    # 叶面浅色纹
    poly(d, [(80, 52), (40, 66), (28, 90), (54, 84), (80, 64)], WHALE_BELLY)
    poly(d, [(90, 52), (130, 66), (142, 90), (116, 84), (90, 64)], WHALE_BELLY)
    return finish(img, w, h)


# ---------------------------------------------------------------- 鳍发饰
def make_fin() -> Image.Image:
    """头侧小鲸鳍发饰（代替兽耳的鲸元素）。70x46，根部在右。"""
    w, h = 70, 46
    img, d = canvas(w, h)
    poly(d, [(66, 10), (36, 6), (10, 22), (6, 36), (28, 40), (52, 32), (66, 24)],
         WHALE_BLUE, OUTLINE, 3)
    poly(d, [(60, 14), (38, 12), (20, 24), (18, 32), (36, 34), (54, 28)], WHALE_BELLY)
    return finish(img, w, h)


# ---------------------------------------------------------------- 喷水
def make_spout() -> Image.Image:
    """头顶小喷水柱 + 水花。60x80，锚点底部。"""
    w, h = 60, 80
    img, d = canvas(w, h)
    poly(d, [(26, 80), (34, 80), (33, 30), (27, 30)], SPOUT + (220,))
    for cx, cy, r in [(30, 20, 9), (16, 32, 6), (44, 32, 6), (8, 44, 4), (52, 44, 4)]:
        ellipse(d, cx, cy, r, r, SPOUT + (200,))
    return finish(img, w, h)


# ---------------------------------------------------------------- 表情（叠在 head 脸部区域）
# 脸部中心在 head 贴图坐标 (90, 104)；表情画布 160x110，运行时对齐脸心。
def _face_base(w=160, h=110):
    return canvas(w, h)


def _big_eye(d, ex, ey, iris=EYE_IRIS):
    """anime 大眼：白底+虹膜+瞳孔+双高光。"""
    ellipse(d, ex, ey, 13, 16, (255, 255, 255), EYE_DARK, 3)
    ellipse(d, ex, ey + 2, 10, 13, iris)
    ellipse(d, ex, ey + 4, 6, 8, EYE_DARK)
    ellipse(d, ex - 4, ey - 5, 4, 5, (255, 255, 255, 240))
    ellipse(d, ex + 5, ey + 7, 2, 2.5, (255, 255, 255, 170))
    # 上睫毛
    d.arc([(ex - 14) * SS, (ey - 18) * SS, (ex + 14) * SS, (ey + 6) * SS],
          200, 340, fill=EYE_DARK, width=4 * SS)


def make_face_normal() -> Image.Image:
    w, h = 160, 110
    img, d = _face_base(w, h)
    _big_eye(d, 48, 46)
    _big_eye(d, 112, 46)
    # 小 ω 嘴
    d.arc([(72) * SS, (78) * SS, (80) * SS, (86) * SS], 0, 180, fill=MOUTH, width=2 * SS)
    d.arc([(80) * SS, (78) * SS, (88) * SS, (86) * SS], 0, 180, fill=MOUTH, width=2 * SS)
    return finish(img, w, h)


def make_face_happy() -> Image.Image:
    w, h = 160, 110
    img, d = _face_base(w, h)
    # ^ ^ 弯月笑眼
    for ex in (48, 112):
        d.arc([(ex - 14) * SS, (34) * SS, (ex + 14) * SS, (60) * SS],
              200, 340, fill=EYE_DARK, width=5 * SS)
    # 张嘴笑 + 舌头
    d.pieslice([(66) * SS, (70) * SS, (94) * SS, (96) * SS], 0, 180, fill=(120, 60, 80))
    d.pieslice([(72) * SS, (82) * SS, (88) * SS, (96) * SS], 0, 180, fill=(240, 130, 140))
    d.arc([(66) * SS, (70) * SS, (94) * SS, (96) * SS], 0, 180, fill=MOUTH, width=2 * SS)
    return finish(img, w, h)


def make_face_sleep() -> Image.Image:
    w, h = 160, 110
    img, d = _face_base(w, h)
    for ex in (48, 112):
        d.arc([(ex - 13) * SS, (38) * SS, (ex + 13) * SS, (58) * SS],
              20, 160, fill=EYE_DARK, width=4 * SS)
    # 小 o 嘴
    ellipse(d, 80, 82, 5, 6, MOUTH)
    return finish(img, w, h)


def make_face_sad() -> Image.Image:
    w, h = 160, 110
    img, d = _face_base(w, h)
    for ex in (48, 112):
        _big_eye(d, ex, 50, iris=(90, 140, 200))
        # 下垂眉
        sx = ex - 15 if ex < 80 else ex + 15
        ex2 = ex + 9 if ex < 80 else ex - 9
        d.line([(sx * SS, 24 * SS), (ex2 * SS, 32 * SS)], fill=EYE_DARK, width=3 * SS)
    # 委屈波浪嘴
    d.arc([(70) * SS, (82) * SS, (90) * SS, (96) * SS], 180, 360, fill=MOUTH, width=2 * SS)
    # 泪珠
    ellipse(d, 126, 68, 4, 6, (150, 210, 250, 230))
    return finish(img, w, h)


def make_blush() -> Image.Image:
    w, h = 160, 110
    img, d = _face_base(w, h)
    for cx in (28, 132):
        ellipse(d, cx, 72, 13, 8, CHEEK + (150,))
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


# ---------------------------------------------------------------- AppIcon
def make_appicon() -> Image.Image:
    """1024x1024：深海底 + 鲸鱼娘头像。"""
    s = 1024
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=224, fill=(14, 46, 88))
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([112, 96, 912, 896], fill=(30, 90, 150, 255))
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    img.alpha_composite(glow)
    # 后发
    hb = make_hair_back().resize((760, 830), Image.LANCZOS)
    img.alpha_composite(hb, (132, 130))
    # 头
    head = make_head().resize((680, 642), Image.LANCZOS)
    img.alpha_composite(head, (172, 180))
    # 表情 + 腮红
    face = make_face_normal().resize((600, 412), Image.LANCZOS)
    img.alpha_composite(face, (212, 430))
    blush = make_blush().resize((600, 412), Image.LANCZOS)
    img.alpha_composite(blush, (212, 430))
    # 鳍发饰
    fin = make_fin().resize((240, 158), Image.LANCZOS)
    img.alpha_composite(fin, (96, 330))
    img.alpha_composite(fin.transpose(Image.FLIP_LEFT_RIGHT), (688, 330))
    return img


# ---------------------------------------------------------------- 输出
IMAGESETS = {
    "whale_hair_back": make_hair_back,
    "whale_head": make_head,
    "whale_body": make_body,
    "whale_arm": make_arm,
    "whale_leg": make_leg,
    "whale_tail": make_tail,
    "whale_fin": make_fin,
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

    # 清理旧版鲸鱼本体素材（whale_hair 已废弃）
    old = root / "whale_hair.imageset"
    if old.exists():
        import shutil
        shutil.rmtree(old)
        print("  · 移除旧素材 whale_hair")

    for name, fn in IMAGESETS.items():
        write_imageset(root, name, fn())
        print(f"  ✓ {name}")

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