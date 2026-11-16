"""把 `flutter build windows --release` 的产物打成便携 zip。

用法（在 Clients/whalepet_flutter 下）：
    python tool/package_release.py            # 先构建再打包
    python tool/package_release.py --no-build # 只打包已有的 Release 目录

产物：dist/whalepet-windows-x64-<version>.zip
解压后双击 whalepet_flutter.exe 即可；不需要安装 Flutter / VS 运行库以外的东西
（MSVC 运行库由 flutter build 附带的 DLL + 系统自带组件覆盖）。
"""

from __future__ import annotations

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT / 'build' / 'windows' / 'x64' / 'runner' / 'Release'
DIST = ROOT / 'dist'


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


def package(version: str) -> Path:
    if not RELEASE.is_dir():
        raise SystemExit(f'找不到 Release 目录：{RELEASE}')
    exe = RELEASE / 'whalepet_flutter.exe'
    if not exe.is_file():
        raise SystemExit(f'找不到可执行文件：{exe}')
    DIST.mkdir(parents=True, exist_ok=True)
    out = DIST / f'whalepet-windows-x64-{version}.zip'
    if out.exists():
        out.unlink()
    notes = (
        '鲸鱼娘 Windows 桌宠（便携版）\n'
        '==========================\n\n'
        f'版本：{version}\n'
        '运行：双击 whalepet_flutter.exe\n'
        '配置：右键宠物 → 设置，填 DSH 网关地址与访问令牌\n'
        '语音：设置里开启「开启唤醒词常驻侦听」，需要麦克风与中文离线识别引擎\n'
        '数据：%%APPDATA%%\\WhalePet\\（设置 / DPAPI 令牌 / 存档）\n\n'
        '注意：明文 HTTP + Bearer 只用于内网或可信 Overlay 网络，不要暴露公网。\n'
    )
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for path in sorted(RELEASE.rglob('*')):
            if path.is_file():
                zf.write(path, str(path.relative_to(RELEASE)))
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
    size_mb = out.stat().st_size / (1024 * 1024)
    print(f'OK: {out} ({size_mb:.1f} MiB)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
