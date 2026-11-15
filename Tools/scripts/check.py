#!/usr/bin/env python3
"""Linux 侧静态自检（无 Xcode 也能跑）：
1. Swift 源码括号/引号配平（粗粒度语法哨兵）
2. project.yml / Info.plist / xcassets Contents.json 结构校验
3. PetNode 引用的纹理名与 xcassets imageset 一一对应
4. 单元测试文件存在且覆盖关键类型
5. 素材尺寸与内存预算检查（A8 / 2GB RAM）
6. 语音/本地网络权限声明
7. DSH 插件（清单结构 + node:test 全量用例）

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


def _real_files(paths):
    """过滤 macOS/Samba 产生的 AppleDouble 垃圾文件（._*，二进制元数据）。"""
    return [p for p in paths if not p.name.startswith("._")]


def check_swift_balance():
    print("[1] Swift 括号配平")
    for f in sorted(_real_files(ROOT.glob("WhalePet*/**/*.swift"))):
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
    sets = {p.name.removesuffix(".imageset")
            for p in _real_files(root.glob("*.imageset"))}
    referenced = set()
    for f in _real_files(ROOT.glob("WhalePet/**/*.swift")):
        src = f.read_text()
        referenced |= set(re.findall(r'imageNamed:\s*"([^"]+)"', src))
        # 状态→纹理映射表 / 赋值里的字符串字面量（如 .idle: "pet_idle"、name = "pet_sad"）
        referenced |= set(re.findall(r'[:=]\s*"(pet_[a-z_]+)"', src))
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
    pngs = _real_files((ROOT / "WhalePet/Resources.xcassets").rglob("*.png"))
    total = 0
    for png in pngs:
        with Image.open(png) as im:
            total += im.width * im.height * 4
    mb = total / 1024 / 1024
    # 运行时只加载 10 张立绘 + 背景 + 2 特效；AppIcon 不进显存
    runtime = 0
    for png in pngs:
        if "AppIcon" in str(png):
            continue
        with Image.open(png) as im:
            runtime += im.width * im.height * 4
    rmb = runtime / 1024 / 1024
    if mb < 32 and rmb < 16:
        ok(f"磁盘纹理 ≈ {mb:.1f} MB；运行时显存 ≈ {rmb:.1f} MB（A8 预算内）")
    else:
        bad(f"纹理总量 {mb:.1f} MB / 运行时 {rmb:.1f} MB 超出 A8 预算")


def check_tests():
    print("[5] 单元测试覆盖")
    t = ROOT / "WhalePetTests/PetBrainTests.swift"
    if not t.exists():
        bad("缺少 PetBrainTests.swift")
        return
    src = t.read_text()
    n = len(re.findall(r"func test\w+", src))
    for key in ["PetBrain", "PetVitals", "PetStore", "ServerSettings"]:
        if key in src:
            ok(f"覆盖 {key}")
        else:
            bad(f"未覆盖 {key}")
    ok(f"共 {n} 个测试用例")


def check_voice_permissions():
    print("[6] 语音/本地网络权限声明")
    with open(ROOT / "WhalePet/Support/Info.plist", "rb") as fp:
        plist = plistlib.load(fp)
    for key in ["NSMicrophoneUsageDescription",
                "NSLocalNetworkUsageDescription"]:
        if isinstance(plist.get(key), str) and plist[key]:
            ok(key)
        else:
            bad(f"缺少 {key}")
    ats = plist.get("NSAppTransportSecurity", {})
    if ats.get("NSAllowsLocalNetworking") is True:
        ok("ATS NSAllowsLocalNetworking（仅放行内网 HTTP）")
    else:
        bad("ATS 未配置 NSAllowsLocalNetworking")
    # 只放行本地网络，不允许任意明文 HTTP。
    if ats.get("NSAllowsArbitraryLoads") is True:
        bad("ATS NSAllowsArbitraryLoads=true 过宽，请移除")
    else:
        ok("未启用 NSAllowsArbitraryLoads")


def check_plugin():
    print("[7] DSH 插件（plugin/whalepet-dsh-bridge）")
    import subprocess
    plugin = ROOT / "Plugin/whalepet-dsh-bridge"
    if not plugin.exists():
        bad("缺少 Plugin/whalepet-dsh-bridge/")
        return
    manifest = json.loads((plugin / "package.json").read_text(encoding="utf-8"))
    if not manifest.get("dsh", {}).get("bundle", {}).get("patch"):
        bad("package.json 缺少 dsh.bundle.patch（无法作为 bundle 安装）")
    else:
        ok(f"{manifest.get('name')}@{manifest.get('version')} 声明了 dsh.bundle.patch")
    patch = plugin / "cordis.patch.yml"
    if not patch.exists():
        bad("缺少 cordis.patch.yml")
    elif "whalepet-bridge" not in patch.read_text(encoding="utf-8"):
        bad("cordis.patch.yml 未插入 whalepet-bridge 行")
    else:
        ok("cordis.patch.yml 含 whalepet-bridge 行")
    index = (plugin / "index.js").read_text(encoding="utf-8")
    for needle in ["export const name", "export const inject", "export function apply"]:
        if needle in index:
            ok(needle)
        else:
            bad(f"index.js 缺少 {needle}")
    # 全量 node:test（纯逻辑 / 传输层端到端 / 假 ctx 插件集成）。
    result = subprocess.run(
        ["node", "--test", "test/*.test.js"],
        cwd=str(plugin), capture_output=True, text=True,
    )
    if result.returncode == 0:
        m = re.search(r"(?:ℹ pass|# pass) (\d+)", result.stdout)
        ok(f"插件测试通过（{m.group(1) if m else '?'} 个用例）")
    else:
        bad(f"插件测试失败:\n{(result.stdout + result.stderr)[-800:]}")


def main():
    check_swift_balance()
    check_project()
    check_assets()
    check_memory_budget()
    check_tests()
    check_voice_permissions()
    check_plugin()
    print()
    if FAIL:
        print(f"自检失败：{FAIL} 个问题")
        sys.exit(1)
    print("全部通过 ✅（Swift 编译与真机验证仍需在 macOS/Xcode 上执行）")


if __name__ == "__main__":
    main()