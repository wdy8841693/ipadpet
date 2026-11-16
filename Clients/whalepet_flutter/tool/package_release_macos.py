"""把 `flutter build macos --release` 的产物打成便携 zip。

用法（在 Clients/whalepet_flutter 下）：
    python3 tool/package_release_macos.py            # 先构建再打包
    python3 tool/package_release_macos.py --no-build # 只打包已有的 App

产物：dist/whalepet-macos-<version>.zip
解压后把 whalepet_flutter.app 拖进「应用程序」即可；未做公证，
首次运行需要「右键 → 打开」绕过 Gatekeeper（或自行 ad-hoc 签名/公证）。
"""

from __future__ import annotations

import argparse
import io
import os
import plistlib
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build' / 'macos' / 'Build' / 'Products' / 'Release' / 'whalepet_flutter.app'
DIST = ROOT / 'dist'


def read_version() -> str:
    text = io.open(ROOT / 'pubspec.yaml', encoding='utf-8').read()
    m = re.search(r'^version:\s*([^\s#]+)', text, re.M)
    return m.group(1) if m else '0.0.0'


def build() -> None:
    env = os.environ.copy()
    env.setdefault('PUB_HOSTED_URL', 'https://pub.flutter-io.cn')
    env.setdefault('FLUTTER_STORAGE_BASE_URL', 'https://storage.flutter-io.cn')
    subprocess.run(['flutter', 'build', 'macos', '--release'],
                   cwd=str(ROOT), env=env, check=True)


def ensure_adhoc_signed() -> None:
    """没配开发者证书时做 ad-hoc 签名，避免直接双击被系统杀掉。"""
    codesign = shutil.which('codesign')
    if not codesign:
        return
    identity = subprocess.run([codesign, '-dv', str(APP)], capture_output=True, text=True)
    if 'Authority=' in (identity.stderr or ''):
        return
    subprocess.run([codesign, '--force', '--deep', '--sign', '-', str(APP)], check=False)


def package(version: str) -> Path:
    if not APP.is_dir():
        raise SystemExit(f'找不到 App：{APP}')
    plist_path = APP / 'Contents' / 'Info.plist'
    if plist_path.is_file():
        with plist_path.open('rb') as fh:
            plist = plistlib.load(fh)
        if not plist.get('LSUIElement'):
            raise SystemExit('Info.plist 缺 LSUIElement：桌宠会出现在 Dock 里')

    DIST.mkdir(parents=True, exist_ok=True)
    out = DIST / f'whalepet-macos-{version}.zip'
    if out.exists():
        out.unlink()

    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for path in sorted(APP.rglob('*')):
            arcname = Path('whalepet_flutter.app') / path.relative_to(APP)
            if path.is_dir():
                continue
            # 符号链接（Framework 里的版本链）按链接本身写入。
            if path.is_symlink():
                info = zipfile.ZipInfo(str(arcname))
                info.create_system = 3
                info.external_attr = (0o120777 << 16)
                zf.writestr(info, str(os.readlink(path)))
                continue
            zf.write(path, str(arcname))
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--no-build', action='store_true', help='跳过 flutter build')
    args = parser.parse_args()

    version = read_version()
    if not args.no_build:
        build()
    ensure_adhoc_signed()
    out = package(version)
    size_mib = out.stat().st_size / (1024 * 1024)
    print(f'打包完成：{out}（{size_mib:.1f} MiB）')
    print('提示：未公证，首次运行请「右键 → 打开」。')


if __name__ == '__main__':
    main()
