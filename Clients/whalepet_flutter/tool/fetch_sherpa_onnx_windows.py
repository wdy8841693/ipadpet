#!/usr/bin/env python3
"""拉取 Windows 版 sherpa-onnx 运行时与本地模型（docs/CROSS_PLATFORM.md §7.9 / §10.3）。

产物落在 ``windows/.sherpa/``（已 gitignore，不入库）：

.. code-block:: text

    windows/.sherpa/
    ├── lib/                      运行时（app-local 方式随包发布）
    │   ├── sherpa-onnx-c-api.dll
    │   ├── sherpa-onnx-cxx-api.dll
    │   ├── onnxruntime.dll
    │   └── onnxruntime_providers_shared.dll
    └── model/                    本地模型
        ├── KWS：encoder/decoder/joiner/tokens（唤醒词）
        └── ASR：encoder/decoder/joiner/tokens（听写）

为什么要脚本而不是入库：onnxruntime 动态库单个约 17MB，中文 ASR 模型约 170MB，
进仓库会让克隆体积翻几倍。仓库只留脚本，出包时现场拉。

下载源（都是国内可达的等效来源）：

- 运行时：npm 官方包 ``sherpa-onnx-win-x64``（与 GitHub Releases 同源产物；
  GitHub 在部分网络下不可达，npm registry 反而通）；
- 模型：HuggingFace 镜像 ``https://hf-mirror.com``（可用 ``WHALEPET_HF_ENDPOINT`` 覆盖）。

用法：

.. code-block:: bash

    python tool/fetch_sherpa_onnx_windows.py            # 运行时 + ASR 模型
    python tool/fetch_sherpa_onnx_windows.py --with-kws # 额外拉 KWS 模型（GitHub 源）
    python tool/fetch_sherpa_onnx_windows.py --force    # 强制重下
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEST = SCRIPT_DIR.parent / "windows" / ".sherpa"

NPM_PACKAGE = "sherpa-onnx-win-x64"
NPM_REGISTRY = "https://registry.npmjs.org"
HF_ENDPOINT = os.environ.get("WHALEPET_HF_ENDPOINT", "https://hf-mirror.com")

# 运行时包里要取出来的文件（其余是 node 绑定，不需要）。
RUNTIME_FILES = (
    "sherpa-onnx-c-api.dll",
    "sherpa-onnx-cxx-api.dll",
    "onnxruntime.dll",
    "onnxruntime_providers_shared.dll",
)

# 中文/中英双语流式听写模型（§7.9：替换 SAPI 听写）。
ASR_REPO = "csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
ASR_FILES = (
    "encoder-epoch-99-avg-1.int8.onnx",
    "decoder-epoch-99-avg-1.onnx",
    "joiner-epoch-99-avg-1.int8.onnx",
    "tokens.txt",
)

# KWS 模型官方发布包（GitHub，国内常被挡；失败不致命，脚本会给出提示）。
KWS_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/"
    "sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"
)
KWS_MEMBERS = (
    "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
    "decoder-epoch-12-avg-2-chunk-16-left-64.onnx",
    "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
    "tokens.txt",
)

USER_AGENT = "WhalePet-fetch/1.0 (+https://github.com/wdy8841693/ipadpet)"


def log(message: str) -> None:
    print(f"==> {message}", flush=True)


def download(url: str, dest: Path, timeout: int = 600) -> bool:
    """下载到 dest（临时文件 + 原子 rename）。失败返回 False。"""
    if dest.exists() and dest.stat().st_size > 0:
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    temp = dest.with_suffix(dest.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            total = int(response.headers.get("Content-Length") or 0)
            done = 0
            with temp.open("wb") as handle:
                while True:
                    chunk = response.read(1024 * 256)
                    if not chunk:
                        break
                    handle.write(chunk)
                    done += len(chunk)
                    if total:
                        print(
                            f"    {done / 1024 / 1024:.1f}/{total / 1024 / 1024:.1f} MiB",
                            end="\r",
                            flush=True,
                        )
            print(" " * 60, end="\r")
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        print(" " * 60, end="\r")
        print(f"    下载失败：{error}", flush=True)
        temp.unlink(missing_ok=True)
        return False
    os.replace(temp, dest)
    return True


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_runtime(force: bool) -> bool:
    """从 npm 官方包取 Windows 运行时 DLL。"""
    lib_dir = DEST / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    wanted = [name for name in RUNTIME_FILES if force or not (lib_dir / name).exists()]
    if not wanted:
        log("运行时已就位，跳过")
        return True

    log(f"查询 npm 包 {NPM_PACKAGE}")
    try:
        with urllib.request.urlopen(
            urllib.request.Request(
                f"{NPM_REGISTRY}/{NPM_PACKAGE}", headers={"User-Agent": USER_AGENT}
            ),
            timeout=60,
        ) as response:
            meta = json.loads(response.read().decode("utf-8"))
        version = meta["dist-tags"]["latest"]
        tarball = meta["versions"][version]["dist"]["tarball"]
    except (urllib.error.URLError, KeyError, TimeoutError, OSError) as error:
        print(f"    npm 元数据获取失败：{error}", file=sys.stderr)
        return False

    cache = DEST / "pkg" / f"{NPM_PACKAGE}-{version}.tgz"
    log(f"下载运行时 {version}")
    if not download(tarball, cache):
        return False
    print(f"    sha256 {sha256(cache)}")

    log("解包运行时 DLL")
    with tarfile.open(cache, "r:gz") as archive:
        for member in archive.getmembers():
            name = os.path.basename(member.name)
            if name not in RUNTIME_FILES:
                continue
            source = archive.extractfile(member)
            if source is None:
                continue
            target = lib_dir / name
            with target.open("wb") as handle:
                shutil.copyfileobj(source, handle)
            print(f"    {name}  {target.stat().st_size / 1024 / 1024:.1f} MiB")
    return True


def fetch_asr(force: bool) -> bool:
    """拉中文流式听写模型（HF 镜像）。"""
    model_dir = DEST / "model"
    model_dir.mkdir(parents=True, exist_ok=True)
    log(f"拉取 ASR 模型（{ASR_REPO}）")
    ok = True
    for name in ASR_FILES:
        target = model_dir / name
        if not force and target.exists() and target.stat().st_size > 0:
            continue
        url = f"{HF_ENDPOINT}/{ASR_REPO}/resolve/main/{name}"
        if not download(url, target):
            ok = False
            break
        print(f"    {name}  {target.stat().st_size / 1024 / 1024:.1f} MiB")
    return ok


def fetch_kws(force: bool) -> bool:
    """拉 KWS 模型（GitHub 官方发布包；国内网络常常不可达）。"""
    model_dir = DEST / "model"
    model_dir.mkdir(parents=True, exist_ok=True)
    if not force and (model_dir / "tokens.txt").exists():
        log("KWS 模型已就位，跳过")
        return True
    log("拉取 KWS 模型（GitHub Releases，国内常被挡）")
    cache = DEST / "pkg" / "kws-model.tar.bz2"
    if not download(KWS_URL, cache):
        print(
            "    提示：GitHub 不可达时，可用 sherpa 的 ASR 模型 + WakeMatcher\n"
            "          走「整段 ASR 匹配唤醒词」路线（与 Android/macOS 同一套语义）。",
            flush=True,
        )
        return False
    with tarfile.open(cache, "r:bz2") as archive:
        for member in archive.getmembers():
            name = os.path.basename(member.name)
            if name not in KWS_MEMBERS:
                continue
            source = archive.extractfile(member)
            if source is None:
                continue
            with (model_dir / name).open("wb") as handle:
                shutil.copyfileobj(source, handle)
            print(f"    {name}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="拉取 Windows 版 sherpa-onnx 运行时与模型")
    parser.add_argument("--with-kws", action="store_true", help="额外拉 KWS（唤醒词）模型")
    parser.add_argument("--no-asr", action="store_true", help="不拉 ASR 模型")
    parser.add_argument("--force", action="store_true", help="强制重新下载")
    args = parser.parse_args()

    log(f"目标目录：{DEST}")
    ok = fetch_runtime(args.force)
    if ok and not args.no_asr:
        ok = fetch_asr(args.force)
    if ok and args.with_kws:
        fetch_kws(args.force)

    print()
    log("完成，目录内容：")
    for path in sorted(DEST.rglob("*")):
        if path.is_file():
            print(f"    {path.relative_to(DEST)}  {path.stat().st_size / 1024 / 1024:.1f} MiB")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
