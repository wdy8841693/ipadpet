#!/usr/bin/env python3
"""从开源项目 dsh-whale-musume（MIT）导入鲸鱼娘立绘，替换程序化角色素材。

来源: https://github.com/Sutera-Diffusus/dsh-whale-musume
      npm 包 dsh-whale-musume（assets/generated/*.webp, 512x512 RGBA）
许可: MIT, Copyright (c) 2026 Sutera-Diffusus（见 docs/THIRD-PARTY-NOTICES.md）

处理:
  - 按状态映射挑选立绘 → 裁剪透明边 → 统一画布高度 → PNG imageset
  - 背景渐变 / 爱心 / 小鱼干仍用本地 generate_assets.py 的原创件
  - AppIcon 用 idle-cute 头像合成

用法:
  python3 Tools/art/import_upstream.py --src <解包目录>/assets/generated \
      [--out WhalePet/Resources.xcassets]
"""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# 状态 → 上游立绘名（不含 dsh-whale-state- 前缀）
STATE_MAP = {
    "pet_idle":   "idle-cute",     # 待机：双手交叠女仆站姿
    "pet_walk":   "tail-swing",    # 散步：摇尾巴（配合位移）
    "pet_swim":   "daily-stretch", # 巡游：伸展（配合漂浮位移）
    "pet_happy":  "react-head",    # 摸头：脸红举手
    "pet_eat":    "eat",           # 投喂：吃点心
    "pet_sleep":  "sleep",         # 睡觉：闭眼坐姿
    "pet_drag":   "pick-up",       # 拖拽：被拎起来
    "pet_play":   "celebrate",     # 玩耍：欢呼彩带
    "pet_sad":    "failure",       # 低落：委屈
    "pet_greet":  "greet",         # 打招呼：挥手
}

TARGET_H = 420          # 统一逻辑高度（点），宽按比例
CANVAS_W = 420          # 统一画布宽（居中），保证锚点一致


def trim_alpha(im: Image.Image, pad: int = 4) -> Image.Image:
    bbox = im.getbbox()
    if not bbox:
        return im
    x0, y0, x1, y1 = bbox
    x0 = max(0, x0 - pad); y0 = max(0, y0 - pad)
    x1 = min(im.width, x1 + pad); y1 = min(im.height, y1 + pad)
    return im.crop((x0, y0, x1, y1))


def normalize(im: Image.Image) -> Image.Image:
    """裁剪透明边 → 等比缩放到 TARGET_H → 放入统一画布（底部对齐）。"""
    im = trim_alpha(im.convert("RGBA"))
    scale = TARGET_H / im.height
    w = max(1, round(im.width * scale))
    im = im.resize((w, TARGET_H), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS_W, TARGET_H), (0, 0, 0, 0))
    canvas.alpha_composite(im, ((CANVAS_W - w) // 2, 0))
    return canvas


def write_imageset(root: Path, name: str, img: Image.Image):
    d = root / f"{name}.imageset"
    d.mkdir(parents=True, exist_ok=True)
    fname = f"{name}.png"
    img.save(d / fname, optimize=True)
    contents = {
        "images": [
            {"idiom": "universal", "filename": fname, "scale": "1x"},
            {"idiom": "universal", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (d / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def make_appicon(src: Path, root: Path):
    s = 1024
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=224, fill=(14, 46, 88))
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([112, 96, 912, 896], fill=(30, 90, 150, 255))
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    img.alpha_composite(glow)
    girl = Image.open(src / "dsh-whale-state-idle-cute.webp").convert("RGBA")
    girl = trim_alpha(girl)
    girl.thumbnail((880, 880), Image.LANCZOS)
    img.alpha_composite(girl, ((s - girl.width) // 2, (s - girl.height) // 2 + 30))

    icon_dir = root / "AppIcon.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    img.save(icon_dir / "icon_1024.png")
    sizes = [("20", "1x", 20), ("20", "2x", 40), ("29", "1x", 29), ("29", "2x", 58),
             ("40", "1x", 40), ("40", "2x", 80), ("76", "1x", 76), ("76", "2x", 152),
             ("83.5", "2x", 167)]
    images = []
    for pt, scale, px in sizes:
        fn = f"icon_{px}.png"
        img.resize((px, px), Image.LANCZOS).save(icon_dir / fn)
        images.append({"size": f"{pt}x{pt}", "idiom": "ipad", "filename": fn, "scale": scale})
    images.append({"size": "1024x1024", "idiom": "ios-marketing",
                   "filename": "icon_1024.png", "scale": "1x"})
    (icon_dir / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="上游 assets/generated 目录")
    ap.add_argument("--out", default="WhalePet/Resources.xcassets")
    args = ap.parse_args()
    src, root = Path(args.src), Path(args.out)

    # 移除旧程序化角色部件（保留背景/特效）
    obsolete = ["whale_hair_back", "whale_head", "whale_body", "whale_arm", "whale_leg",
                "whale_tail", "whale_fin", "whale_spout", "whale_blush",
                "whale_face_normal", "whale_face_happy", "whale_face_sleep", "whale_face_sad"]
    for name in obsolete:
        p = root / f"{name}.imageset"
        if p.exists():
            shutil.rmtree(p)
            print(f"  · 移除旧部件 {name}")

    for out_name, up_name in STATE_MAP.items():
        f = src / f"dsh-whale-state-{up_name}.webp"
        if not f.exists():
            raise SystemExit(f"缺少上游素材: {f}")
        write_imageset(root, out_name, normalize(Image.open(f)))
        print(f"  ✓ {out_name} ← {up_name}")

    make_appicon(src, root)
    print("  ✓ AppIcon ← idle-cute")
    print(f"完成 → {root}")


if __name__ == "__main__":
    main()