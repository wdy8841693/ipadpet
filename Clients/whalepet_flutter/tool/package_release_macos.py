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
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build' / 'macos' / 'Build' / 'Products' / 'Release' / 'whalepet_flutter.app'
DIST = ROOT / 'dist'
SHERPA_DIR = ROOT / 'macos' / '.sherpa'
FETCH_SCRIPT = ROOT / 'tool' / 'fetch_sherpa_onnx.sh'

# 构建时跳过的目录：产物/依赖缓存/其它平台/大文件。
# 目的两个：一是快，二是别把别处的 `._` 垃圾文件带进构建目录。
BUILD_EXCLUDES = (
    'build/', '.dart_tool/', 'dist/', '.git/',
    'android/', 'ios/', 'windows/', 'linux/',
)


def read_version() -> str:
    text = io.open(ROOT / 'pubspec.yaml', encoding='utf-8').read()
    m = re.search(r'^version:\s*([^\s#]+)', text, re.M)
    return m.group(1) if m else '0.0.0'


def ensure_sherpa_payload() -> bool:
    """确保本地唤醒词（sherpa-onnx）载荷就位；缺了就现场拉。

    载荷约 40MB（onnxruntime 动态库 + KWS 模型），不入库，由出包时拉取，
    用户拿到的 App 仍然是离线可用的（§10.2）。
    """
    helper = SHERPA_DIR / 'bin' / 'whalepet-kws'
    if helper.is_file():
        return True
    if not FETCH_SCRIPT.is_file():
        print('提示：找不到 tool/fetch_sherpa_onnx.sh，本次出包不带本地唤醒词。')
        return False
    print('==> 拉取本地唤醒词载荷（sherpa-onnx，约 40MB）…')
    subprocess.run(['bash', str(FETCH_SCRIPT)], cwd=str(ROOT), check=True)
    return helper.is_file()


def sign_kws_payload(app: Path) -> None:
    """给 App 里的唤醒词进程和动态库做 ad-hoc 签名。

    macOS 上 App 一旦被签名，加载的动态库也得有签名，否则会被系统拒掉。
    这些文件在 Resources/kws/ 下，不是标准的 Frameworks 目录，
    `codesign --deep` 不一定会覆盖到，所以逐个签。
    """
    codesign = shutil.which('codesign')
    if not codesign:
        return
    payload = app / 'Contents' / 'Resources' / 'kws'
    if not payload.is_dir():
        return
    targets = list(payload.rglob('*.dylib')) + list(payload.rglob('whalepet-kws'))
    for target in targets:
        if target.is_file():
            subprocess.run([codesign, '--force', '--sign', '-', str(target)],
                           check=False, capture_output=True)


def build() -> Path:
    """在**本地盘**构建 macOS App，返回 .app 路径。

    为什么要绕开仓库目录直接构建：仓库在 Samba 共享上，macOS 往共享盘拷贝
    文件时会生成 `._` 资源叉垃圾文件，Xcode 把 Flutter 引擎产物拷进 App 包
    时也会带上它们，于是 codesign 报
    `code object is not signed at all`（子组件 `._._App`）而失败。
    在本地临时目录构建就没有这个问题。

    产物仍然按原样打 zip，用户拿到手的 App 不受影响。
    """
    env = os.environ.copy()
    env.setdefault('PUB_HOSTED_URL', 'https://pub.flutter-io.cn')
    env.setdefault('FLUTTER_STORAGE_BASE_URL', 'https://storage.flutter-io.cn')

    scratch = Path(tempfile.mkdtemp(prefix='whalepet-macos-build-'))
    print(f'==> 在本地临时目录构建：{scratch}')
    rsync = shutil.which('rsync')
    if rsync:
        cmd = [rsync, '-a', '--exclude', '._*']
        for pattern in BUILD_EXCLUDES:
            cmd += ['--exclude', pattern]
        cmd += [str(ROOT) + '/', str(scratch) + '/']
        subprocess.run(cmd, check=True)
    else:
        shutil.copytree(ROOT, scratch, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('build', '.dart_tool', 'dist', '._*'))

    # .dart_tool 里的 package_config 记的是绝对路径，换目录后要重新生成。
    subprocess.run(['flutter', 'pub', 'get'], cwd=str(scratch), env=env, check=True)
    subprocess.run(['flutter', 'build', 'macos', '--release'],
                   cwd=str(scratch), env=env, check=True)
    app = scratch / 'build' / 'macos' / 'Build' / 'Products' / 'Release' / 'whalepet_flutter.app'
    if not app.is_dir():
        raise SystemExit(f'构建结束但找不到 App：{app}')
    return app


def ensure_adhoc_signed(app: Path) -> None:
    """没配开发者证书时做 ad-hoc 签名，避免直接双击被系统杀掉。"""
    codesign = shutil.which('codesign')
    if not codesign:
        return
    identity = subprocess.run([codesign, '-dv', str(app)], capture_output=True, text=True)
    if 'Authority=' in (identity.stderr or ''):
        return
    subprocess.run([codesign, '--force', '--deep', '--sign', '-', str(app)], check=False)


def package(version: str, app: Path) -> Path:
    if not app.is_dir():
        raise SystemExit(f'找不到 App：{app}')
    plist_path = app / 'Contents' / 'Info.plist'
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
        for path in sorted(app.rglob('*')):
            arcname = Path('whalepet_flutter.app') / path.relative_to(app)
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
    parser.add_argument('--no-kws', action='store_true',
                        help='不拉取本地唤醒词载荷（出不含真 KWS 的包）')
    args = parser.parse_args()

    version = read_version()
    has_kws = False
    if args.no_kws:
        print('提示：--no-kws，本次出包不带本地唤醒词（唤醒退回文本匹配）。')
    else:
        has_kws = ensure_sherpa_payload()
    if args.no_build:
        if not APP.is_dir():
            raise SystemExit(f'--no-build 但找不到已有产物：{APP}')
        app = APP
    else:
        app = build()
    if has_kws:
        sign_kws_payload(app)
    ensure_adhoc_signed(app)
    out = package(version, app)
    size_mib = out.stat().st_size / (1024 * 1024)
    print(f'打包完成：{out}（{size_mib:.1f} MiB）')
    if has_kws:
        print('包含：本地唤醒词（sherpa-onnx KWS，离线可用）')
    else:
        print('不包含：本地唤醒词（唤醒走「系统识别 + 文本匹配」）')
    print('提示：未公证，首次运行请「右键 → 打开」。')


if __name__ == '__main__':
    main()
