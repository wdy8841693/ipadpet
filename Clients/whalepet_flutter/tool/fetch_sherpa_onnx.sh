#!/usr/bin/env bash
# 拉取 sherpa-onnx 运行时与中文 KWS 模型，供 macOS 端「本地唤醒词」使用。
#
# 产物落在 macos/.sherpa/（已 gitignore，不入库）：
#   macos/.sherpa/include/sherpa-onnx/c-api/c-api.h   C API 头文件
#   macos/.sherpa/lib/*.dylib                         运行时（onnxruntime + sherpa）
#   macos/.sherpa/model/*                             KWS 模型（int8 版，约 5MB）
#
# 为什么要脚本而不是入库：onnxruntime 动态库单个 31MB（x86_64），加上模型约 40MB，
# 进仓库会让克隆体积翻几倍。仓库只留脚本，出包时现场拉。
#
# 用法：
#   tool/fetch_sherpa_onnx.sh            # 按当前机器架构拉取
#   tool/fetch_sherpa_onnx.sh --universal # 拉 universal2（同时支持 Intel 与 Apple Silicon）
#   tool/fetch_sherpa_onnx.sh --force    # 强制重新下载
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${SCRIPT_DIR}/../macos/.sherpa"

SHERPA_VERSION="v2.0.1"
KWS_MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"
C_API_URL="https://cdn.jsdelivr.net/gh/k2-fsa/sherpa-onnx@${SHERPA_VERSION}/sherpa-onnx/c-api/c-api.h"

# KWS 关键词：模型以「拼音（声母+韵母）」为建模单元，所以关键词要写成拼音 token。
# 小鲸小鲸 → x iǎo j īng x iǎo j īng
KEYWORDS_FILE="${SCRIPT_DIR}/kws_keywords.txt"

force=0
flavor="auto"
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --universal) flavor="universal" ;;
    --x64) flavor="x64" ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$flavor" == "auto" ]]; then
  case "$(uname -m)" in
    arm64) flavor="arm64" ;;
    *) flavor="x64" ;;
  esac
fi

case "$flavor" in
  x64)      LIB_ARCH="x64" ;;
  arm64)    LIB_ARCH="arm64" ;;
  universal) LIB_ARCH="universal2" ;;
esac

LIB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/sherpa-onnx-${SHERPA_VERSION}-osx-${LIB_ARCH}-shared-lib.tar.bz2"

echo "==> 目标目录: ${DEST}"
echo "==> 架构: ${LIB_ARCH}"

mkdir -p "${DEST}/include/sherpa-onnx/c-api" "${DEST}/lib" "${DEST}/model"

if [[ $force -eq 1 ]]; then
  echo "==> --force：清空旧的 sherpa-onnx 产物"
  rm -rf "${DEST}/include" "${DEST}/lib" "${DEST}/model"
  mkdir -p "${DEST}/include/sherpa-onnx/c-api" "${DEST}/lib" "${DEST}/model"
fi

# ---- C API 头文件 ----
if [[ ! -f "${DEST}/include/sherpa-onnx/c-api/c-api.h" || $force -eq 1 ]]; then
  echo "==> 下载 C API 头文件"
  curl -sSL --retry 3 -o "${DEST}/include/sherpa-onnx/c-api/c-api.h" "${C_API_URL}"
fi

# ---- 运行时动态库 ----
if [[ ! -f "${DEST}/lib/libsherpa-onnx-c-api.dylib" || $force -eq 1 ]]; then
  echo "==> 下载运行时（${LIB_ARCH}）"
  tmp="$(mktemp -d)"
  curl -sSL --retry 3 -o "${tmp}/lib.tar.bz2" "${LIB_URL}"
  tar -xjf "${tmp}/lib.tar.bz2" -C "${tmp}"
  find "${tmp}" -name "libsherpa-onnx-c-api.dylib" -exec cp {} "${DEST}/lib/" \;
  find "${tmp}" -name "libonnxruntime.dylib" -exec cp {} "${DEST}/lib/" \;
  rm -rf "${tmp}"
fi

# ---- KWS 模型（int8 版，体积约为 fp32 的 1/3）----
if [[ ! -f "${DEST}/model/tokens.txt" || $force -eq 1 ]]; then
  echo "==> 下载中文 KWS 模型"
  tmp="$(mktemp -d)"
  curl -sSL --retry 3 -o "${tmp}/model.tar.bz2" "${KWS_MODEL_URL}"
  tar -xjf "${tmp}/model.tar.bz2" -C "${tmp}"
  model_dir="$(find "${tmp}" -maxdepth 1 -type d -name "sherpa-onnx-kws-*" | head -1)"
  if [[ -z "$model_dir" ]]; then
    echo "模型包结构异常" >&2
    exit 1
  fi
  cp "${model_dir}/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "${DEST}/model/"
  cp "${model_dir}/decoder-epoch-12-avg-2-chunk-16-left-64.onnx" "${DEST}/model/"
  cp "${model_dir}/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx" "${DEST}/model/"
  cp "${model_dir}/tokens.txt" "${DEST}/model/"
  rm -rf "${tmp}"
fi

# ---- 关键词表（随包带上产品自己的唤醒词）----
cp "${KEYWORDS_FILE}" "${DEST}/model/keywords.txt"

# ---- 编译常驻 KWS 进程 ----
# 二进制放在 .sherpa/bin，动态库在 .sherpa/lib → rpath 用 @loader_path/../lib，
# 这样整目录一起拷进 App 包后仍然能找到库。
echo "==> 编译 KWS 常驻进程"
mkdir -p "${DEST}/bin"
clang++ -O2 -std=c++17 \
  -o "${DEST}/bin/whalepet-kws" \
  "${SCRIPT_DIR}/whalepet_kws.cpp" \
  -I"${DEST}/include" \
  -L"${DEST}/lib" -lsherpa-onnx-c-api \
  -Wl,-rpath,@loader_path/../lib

echo "==> 完成："
du -sh "${DEST}/lib" "${DEST}/model" "${DEST}/bin" | sed 's/^/    /'
echo "    合计: $(du -sh "${DEST}" | cut -f1)"
