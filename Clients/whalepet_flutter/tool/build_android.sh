#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Android 打包脚本：把工程复制到**本地磁盘**再构建，产物复制回 dist/。
#
# 为什么不能原地构建：工程可能放在网络盘（\\nas\share），而 Windows 版
# flutter/gradle 的 .bat 不能以 UNC 路径为工作目录（cmd.exe 直接报错），
# 在共享盘上跑 Gradle 也慢得离谱。
#
# 用法：
#   bash tool/build_android.sh              # 通用 APK（arm64 + armeabi-v7a + x86_64）
#   MODE=debug bash tool/build_android.sh   # debug 包
#   FLUTTER_BIN=/path/to/flutter bash tool/build_android.sh
#
# 前置：Flutter SDK 3.50.x、Android SDK（platform 36 / build-tools 36 / platform-tools）、JDK 17。
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${MODE:-release}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  echo "找不到 flutter 命令；请把 Flutter SDK 的 bin 加进 PATH，或设置 FLUTTER_BIN" >&2
  exit 1
fi

# Gradle 需要 JDK 17：没显式设置就从 PATH 里的 java 反推
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
  _jh="$(dirname "$(dirname "$(command -v java)")")"
  if command -v cygpath >/dev/null 2>&1; then
    JAVA_HOME="$(cygpath -w "$_jh")"
  else
    JAVA_HOME="$_jh"
  fi
  export JAVA_HOME
fi
if [ -z "${JAVA_HOME:-}" ]; then
  echo "提示：JAVA_HOME 未设置且 PATH 里没有 java —— Gradle 会直接失败。" >&2
fi

# 版本号（pubspec 的 version: x.y.z+build）
VERSION="$(grep -E '^version:' "$ROOT/pubspec.yaml" | head -1 | sed 's/version:[[:space:]]*//' | tr -d '\r')"
VERSION_NAME="${VERSION%%+*}"

# 本地构建目录
if [ -n "${WHALEPET_ANDROID_BUILD_DIR:-}" ]; then
  WORK="$WHALEPET_ANDROID_BUILD_DIR"
elif command -v cygpath >/dev/null 2>&1; then
  WORK="$(cygpath -m "${LOCALAPPDATA:-$HOME}")/WhalePetAndroidBuild"
else
  WORK="/tmp/whalepet-android-build"
fi

echo "==> 同步源码到本地构建目录：$WORK"
mkdir -p "$WORK"
for d in lib assets android test tool; do
  [ -d "$ROOT/$d" ] || continue
  mkdir -p "$WORK/$d"
  cp -r "$ROOT/$d/." "$WORK/$d/"
done
for f in pubspec.yaml pubspec.lock analysis_options.yaml .metadata; do
  [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$WORK/$f"
done

# android/local.properties 不入库（含本机路径），构建前补一份
FLUTTER_SDK="$(dirname "$(dirname "$(command -v "$FLUTTER_BIN")")")"
if [ -n "${ANDROID_HOME:-}" ]; then
  if command -v cygpath >/dev/null 2>&1; then
    SDK_WIN="$(cygpath -w "$ANDROID_HOME")"
    FLUTTER_WIN="$(cygpath -w "$FLUTTER_SDK")"
  else
    SDK_WIN="$ANDROID_HOME"
    FLUTTER_WIN="$FLUTTER_SDK"
  fi
  printf 'sdk.dir=%s\nflutter.sdk=%s\n' "$SDK_WIN" "$FLUTTER_WIN" \
    > "$WORK/android/local.properties"
fi

cd "$WORK"
echo "==> flutter pub get"
"$FLUTTER_BIN" pub get

echo "==> flutter build apk --$MODE"
"$FLUTTER_BIN" build apk "--$MODE"

APK="$WORK/build/app/outputs/flutter-apk/app-$MODE.apk"
[ -f "$APK" ] || { echo "没找到构建产物：$APK" >&2; exit 1; }

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/whalepet-android-$VERSION_NAME-$MODE.apk"
cp -f "$APK" "$OUT"
ls -lh "$OUT"
echo "完成：$OUT"
