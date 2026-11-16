"""把 `flutter build windows --release` 的产物打成便携 zip。

用法（在 Clients/whalepet_flutter 下）：
    python tool/package_release.py            # 先构建再打包
    python tool/package_release.py --no-build # 只打包已有的 Release 目录

产物：dist/whalepet-windows-x64-<version>.zip

解压后双击 whalepet_flutter.exe 即可，目标机不需要预装 VC++ Redistributable：
`flutter build` 的 Release 目录里只有 exe / flutter_windows.dll / data，而主程序
是**动态链接** MSVC 运行库的（导入表里有 VCRUNTIME140.dll、MSVCP140.dll），
干净 Windows 上直接双击会报「找不到 VCRUNTIME140.dll」。这里按微软支持的
app-local 方式把运行库 DLL 一起打进包（版本取本机 VS/*Windows SDK 的那份）。
"""

from __future__ import annotations

import argparse
import io
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# FLUTTER_BUILD_DIR 可以把构建目录挪走：多人/多会话同时在同一个工程里构建时，
# 共用 build/ 会互相覆盖（而且 Flutter 工具会解析 build/ 里的 .vcxproj）。
BUILD_DIR = Path(os.environ.get('FLUTTER_BUILD_DIR') or (ROOT / 'build'))
RELEASE = BUILD_DIR / 'windows' / 'x64' / 'runner' / 'Release'
DIST = ROOT / 'dist'

# 主程序导入表里点名要的（缺任一个，干净机器上启动就失败）。
REQUIRED_DLLS = ('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
# Win8.1+ 系统自带；只为兼容更老的机器才 app-local 附带，找不到就跳过。
OPTIONAL_DLLS = ('d3dcompiler_47.dll',)

# AOT 发布包里不该出现的调试残留：build/ 目录被 debug 构建污染时，
# kernel_blob.bin（43MB JIT 内核）会留在 Release/data/flutter_assets/ 里，
# 打包时必须剔掉，否则包体翻一倍且运行模式混乱。
DEBUG_ONLY_ARTIFACTS = ('kernel_blob.bin', 'vm_snapshot_data', 'isolate_snapshot_data')

# AOT 快照：release 构建的标志物。
AOT_SNAPSHOT = 'data/app.so'


def read_version() -> str:
    text = io.open(ROOT / 'pubspec.yaml', encoding='utf-8').read()
    m = re.search(r'^version:\s*([^\s#]+)', text, re.M)
    return m.group(1) if m else '0.0.0'


def build() -> None:
    env = os.environ.copy()
    env.setdefault('PUB_HOSTED_URL', 'https://pub.flutter-io.cn')
    env.setdefault('FLUTTER_STORAGE_BASE_URL', 'https://storage.flutter-io.cn')
    subprocess.run(['flutter', 'build', 'windows', '--release'],
                   cwd=str(ROOT), env=env, check=True)


def _search_dirs() -> list[Path]:
    dirs = [RELEASE]
    extra = os.environ.get('WHALEPET_DLL_DIR')
    if extra:
        dirs.insert(0, Path(extra))
    sysroot = os.environ.get('SystemRoot') or os.environ.get('WINDIR')
    if sysroot:
        # 32 位 Python 跑在 64 位系统上时要走 Sysnative 才能看到真正的 System32。
        dirs.append(Path(sysroot) / 'System32')
        dirs.append(Path(sysroot) / 'Sysnative')
    return dirs


def resolve_runtime_dlls() -> tuple[dict[str, Path], list[str]]:
    """返回 (名字 -> 源文件, 缺失的必需项)。"""
    found: dict[str, Path] = {}
    missing: list[str] = []
    for name in REQUIRED_DLLS + OPTIONAL_DLLS:
        required = name in REQUIRED_DLLS
        for d in _search_dirs():
            cand = d / name
            if cand.is_file():
                found[name] = cand
                break
        else:
            if required:
                missing.append(name)
    return found, missing


def package(version: str) -> Path:
    if not RELEASE.is_dir():
        raise SystemExit(f'找不到 Release 目录：{RELEASE}')
    exe = RELEASE / 'whalepet_flutter.exe'
    if not exe.is_file():
        raise SystemExit(f'找不到可执行文件：{exe}')
    aot = RELEASE / AOT_SNAPSHOT
    if not aot.is_file():
        raise SystemExit(
            f'找不到 AOT 快照（{AOT_SNAPSHOT}）：当前目录不是 release 构建产物。\n'
            '请先执行 flutter build windows --release 再打包。')

    dlls, missing = resolve_runtime_dlls()
    if missing:
        raise SystemExit(
            '缺少 MSVC 运行库，打出来的包在干净 Windows 上会启动失败：\n  '
            + '\n  '.join(missing)
            + '\n请装 VS 2022 的「MSVC v143 x64/x86 生成工具」或 VC++ 可再发行组件，'
            '\n或用 WHALEPET_DLL_DIR 指向含这些 DLL 的目录。')

    DIST.mkdir(parents=True, exist_ok=True)
    out = DIST / f'whalepet-windows-x64-{version}.zip'
    if out.exists():
        out.unlink()
    notes = (
        '鲸鱼娘 Windows 桌宠（便携版）\n'
        '==========================\n\n'
        f'版本：{version}\n'
        '运行：双击 whalepet_flutter.exe（整目录一起拷贝，别只拿 exe）\n'
        '配置：右键宠物 → 设置，填 DSH 网关地址与访问令牌\n'
        '语音：设置里开启「开启唤醒词常驻侦听」，需要麦克风与中文离线识别引擎\n'
        '数据：%APPDATA%\\WhalePet\\（设置 / DPAPI 令牌 / 存档）\n\n'
        '环境：Windows 10/11 x64；VC++ 运行库已随包附带（app-local），无需另行安装。\n'
        '依赖：唤醒词用系统自带的 SAPI5 中文识别器（MS-2052-80-DESK / zh-CN），\n'
        '      缺这个语言包时语音唤醒会报「未找到中文识别器」，文字聊天不受影响。\n\n'
        '注意：明文 HTTP + Bearer 只用于内网或可信 Overlay 网络，不要暴露公网。\n'
    )
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for path in sorted(RELEASE.rglob('*')):
            if not path.is_file():
                continue
            if path.name in DEBUG_ONLY_ARTIFACTS:
                continue
            zf.write(path, str(path.relative_to(RELEASE)))
        for name, src in sorted(dlls.items()):
            if not (RELEASE / name).is_file():
                zf.write(src, name)
        zf.writestr('使用说明.txt', notes.encode('utf-8'))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--no-build', action='store_true')
    args = ap.parse_args()
    version = read_version()
    if not args.no_build:
        build()
    out = package(version)
    dlls, _ = resolve_runtime_dlls()
    size_mb = out.stat().st_size / (1024 * 1024)
    print(f'OK: {out} ({size_mb:.1f} MiB)')
    print('   附带运行库：' + ', '.join(sorted(dlls)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
