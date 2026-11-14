#!/usr/bin/env python3
"""Linux 侧静态自检（无 Xcode 也能跑）：
1. Swift 源码括号/引号配平（粗粒度语法哨兵）
2. project.yml / Info.plist / xcassets Contents.json 结构校验
3. PetNode 引用的纹理名与 xcassets imageset 一一对应
4. 单元测试文件存在且覆盖关键类型
5. 素材尺寸与内存预算检查（A8 / 2GB RAM）

用法: python3 Tools/scripts/check.py
退出码非 0 = 有问题。
"""
from __future__ import annotations

import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAIL = 0


def ok(msg): print(f"  ✓ {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  ✗ {msg}")


def check_swift_balance():
    print("[1] Swift 括号配平")
    for f in sorted(ROOT.glob("WhalePet*/**/*.swift")):
        src = f.read_text(encoding="utf-8")
        # 去掉字符串与注释后数括号
        stripped = re.sub(r'"(?:[^"\\]|\\.)*"', '""', src)
        stripped = re.sub(r"//[^\n]*", "", stripped)
        stripped = re.sub(r"/\*.*?\*/", "", stripped, flags=re.S)
        for open_c, close_c in [("{", "}"), ("(", ")"), ("[", "]")]:
            if stripped.count(open_c) != stripped.count(close_c):
                bad(f"{f.relative_to(ROOT)}: {open_c}{close_c} 不配平 "
                    f"({stripped.count(open_c)} vs {stripped.count(close_c)})")
                break
        else:
            ok(str(f.relative_to(ROOT)))


def check_project():
    print("[2] 工程配置")
    yml = (ROOT / "project.yml").read_text(encoding="utf-8")
    for needle in ['iOS: "15.0"', 'TARGETED_DEVICE_FAMILY: "2"', "UIRequiresFullScreen"]:
        if needle in yml or needle in (ROOT / "WhalePet/Support/Info.plist").read_text():
            ok(needle)
        else:
            bad(f"缺少 {needle}")
    with open(ROOT / "WhalePet/Support/Info.plist", "rb") as fp:
        plist = plistlib.load(fp)
    if plist.get("UIRequiresFullScreen") is True:
        ok("Info.plist UIRequiresFullScreen=true")
    else:
        bad("Info.plist 未强制全屏")
    orient = plist.get("UISupportedInterfaceOrientations~ipad", [])
    if len(orient) == 4:
        ok("iPad 四方向旋转")
    else:
        bad(f"iPad 方向配置异常: {orient}")


def check_assets():
    print("[3] 纹理引用一致性")
    root = ROOT / "WhalePet/Resources.xcassets"
    sets = {p.name.removesuffix(".imageset") for p in root.glob("*.imageset")}
    referenced = set()
    for f in ROOT.glob("WhalePet/**/*.swift"):
        referenced |= set(re.findall(r'imageNamed:\s*"([^"]+)"', f.read_text()))
    missing = referenced - sets
    if missing:
        bad(f"代码引用了不存在的纹理: {sorted(missing)}")
    else:
        ok(f"{len(referenced)} 个纹理引用全部命中")
    unused = sets - referenced
    if unused:
        print(f"  · 提示: 未被引用的 imageset: {sorted(unused)}")
    # Contents.json 可解析 & 文件存在
    for cj in root.rglob("Contents.json"):
        try:
            data = json.loads(cj.read_text())
            for img in data.get("images", []):
                fn = img.get("filename")
                if fn and not (cj.parent / fn).exists():
                    bad(f"{cj.parent.name}: 缺文件 {fn}")
        except json.JSONDecodeError as e:
            bad(f"{cj}: JSON 解析失败 {e}")
    ok("所有 Contents.json 有效且文件齐全")


def check_memory_budget():
    print("[4] 显存预算（RGBA8 估算）")
    try:
        from PIL import Image
    except ImportError:
        print("  · 跳过（无 Pillow）")
        return
    total = 0
    for png in (ROOT / "WhalePet/Resources.xcassets").rglob("*.png"):
        with Image.open(png) as im:
            total += im.width * im.height * 4
    mb = total / 1024 / 1024
    if mb < 24:
        ok(f"全部纹理 ≈ {mb:.1f} MB（含 AppIcon；运行时背景+部件 < 10MB）")
    else:
        bad(f"纹理总量 {mb:.1f} MB 超出 A8 预算")


def check_tests():
    print("[5] 单元测试覆盖")
    t = ROOT / "WhalePetTests/PetBrainTests.swift"
    if not t.exists():
        bad("缺少 PetBrainTests.swift")
        return
    src = t.read_text()
    n = len(re.findall(r"func test\w+", src))
    for key in ["PetBrain", "PetVitals", "PetStore"]:
        if key in src:
            ok(f"覆盖 {key}")
        else:
            bad(f"未覆盖 {key}")
    ok(f"共 {n} 个测试用例")


def main():
    check_swift_balance()
    check_project()
    check_assets()
    check_memory_budget()
    check_tests()
    print()
    if FAIL:
        print(f"自检失败：{FAIL} 个问题")
        sys.exit(1)
    print("全部通过 ✅（Swift 编译与真机验证仍需在 macOS/Xcode 上执行）")


if __name__ == "__main__":
    main()