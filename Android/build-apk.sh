#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 不依赖 Gradle 的 APK 构建脚本（只用 JDK + Android SDK 的 aapt2/d8/apksigner）
#
# 用法：
#   ./build-apk.sh
#   JDK_HOME=... BT_DIR=... PLATFORM_JAR=... ./build-apk.sh
#
# 需要的三样东西（装过 Android Studio 的机器一般都有，指到对应目录即可）：
#   JDK_HOME      JDK 17（含 javac / keytool）
#   BT_DIR        Android SDK build-tools/<版本>（含 aapt2、d8、zipalign、apksigner）
#   PLATFORM_JAR  Android SDK platforms/android-33/android.jar
#
# 产物：build/whalepet-android.apk（debug 签名，可直接 adb install）
# 中间文件写在系统临时目录，不污染仓库（仓库可能在网络盘上，慢且不适合编译）。
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# --- 工具链定位 -------------------------------------------------------------
JDK_HOME="${JDK_HOME:-/c/Users/hp/abuild/jdk/jdk-17.0.21+9}"
BT_DIR="${BT_DIR:-/c/Users/hp/abuild/sdk/bt/android-14}"
PLATFORM_JAR="${PLATFORM_JAR:-/c/Users/hp/abuild/sdk/platform/android-13/android.jar}"

if [ -n "${ANDROID_HOME:-}" ]; then
  if [ ! -f "$BT_DIR/aapt2.exe" ] && [ ! -f "$BT_DIR/aapt2" ]; then
    latest_bt="$(ls -1 "$ANDROID_HOME/build-tools" 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$latest_bt" ] && BT_DIR="$ANDROID_HOME/build-tools/$latest_bt"
  fi
fi

exe() { # 兼容 Windows(.exe/.bat) 与 macOS/Linux
  for suffix in .exe .bat .cmd; do
    if [ -f "$1$suffix" ]; then echo "$1$suffix"; return; fi
  done
  echo "$1"
}

# d8.bat / apksigner.bat 依赖 JAVA_HOME（Windows 下要原生路径）
if command -v cygpath >/dev/null 2>&1; then
  export JAVA_HOME="$(cygpath -w "$JDK_HOME")"
else
  export JAVA_HOME="$JDK_HOME"
fi
export PATH="$JDK_HOME/bin:$PATH"

AAPT2="$(exe "$BT_DIR/aapt2")"
D8="$(exe "$BT_DIR/d8")"
ZIPALIGN="$(exe "$BT_DIR/zipalign")"
APKSIGNER="$(exe "$BT_DIR/apksigner")"
JAVAC="$(exe "$JDK_HOME/bin/javac")"
JAR="$(exe "$JDK_HOME/bin/jar")"
KEYTOOL="$(exe "$JDK_HOME/bin/keytool")"

for f in "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER" "$JAVAC" "$KEYTOOL"; do
  [ -f "$f" ] || { echo "缺少构建工具：$f" >&2; exit 1; }
done
[ -f "$PLATFORM_JAR" ] || { echo "找不到 android.jar：$PLATFORM_JAR" >&2; exit 1; }

APP="$ROOT/app/src/main"
OUT_DIR="$ROOT/build"
OUT="$OUT_DIR/whalepet-android.apk"

# Windows 版 javac 用 ';' 分隔 classpath，类 Unix 用 ':'
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) PATH_SEP=';' ;;
  *) PATH_SEP=':' ;;
esac

# 传给 Windows 原生工具的路径统一转成 C:/... 形式（MSYS 的 /c/... 会被打乱）
to_mixed() {
  case "$1" in
    [A-Za-z]:*) echo "$1" ;;                     # 已经是 C:/... 形式
    /*) if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi ;;
    *) echo "$1" ;;
  esac
}
PLATFORM_JAR="$(to_mixed "$PLATFORM_JAR")"

JARS=()
while IFS= read -r j; do [ -n "$j" ] && JARS+=("$(to_mixed "$j")"); done < <(ls -1 "$ROOT"/libs/*.jar 2>/dev/null)
CLASSPATH_ARGS=""
for j in "${JARS[@]:-}"; do
  [ -n "$j" ] || continue
  CLASSPATH_ARGS="${CLASSPATH_ARGS:+$CLASSPATH_ARGS$PATH_SEP}$j"
done

# --- 本地临时构建目录 -------------------------------------------------------
# 注意：Windows 原生工具（javac/d8/aapt2）不认 MSYS 的 /tmp 虚拟路径，
# 所以临时目录要用 `pwd -W` 取成 C:/Users/... 这种双端都认的形式。
TMP_BASE="$(cd /tmp 2>/dev/null && pwd -W 2>/dev/null || echo /tmp)"
WORK="${WHALEPET_BUILD_DIR:-$TMP_BASE/whalepet-build-$$}"
mkdir -p "$WORK"
mkdir -p "$WORK/compiled" "$WORK/classes" "$WORK/dex" "$WORK/gen"
cp -r "$APP/java" "$WORK/java"
cp -r "$APP/res" "$WORK/res"
cp -r "$APP/assets" "$WORK/assets"
echo "构建目录：$WORK"

echo "==> 1/6 编译资源 (aapt2 compile)"
"$AAPT2" compile --dir "$WORK/res" -o "$WORK/compiled/res.zip"

echo "==> 2/6 链接资源与清单 (aapt2 link)"
"$AAPT2" link \
  -o "$WORK/unsigned.apk" \
  -I "$PLATFORM_JAR" \
  --manifest "$APP/AndroidManifest.xml" \
  -R "$WORK/compiled/res.zip" \
  --java "$WORK/gen" \
  -A "$WORK/assets" \
  --min-sdk-version 21 \
  --target-sdk-version 33 \
  --version-code 1 \
  --version-name 1.3.0-android.1 \
  --auto-add-overlay

echo "==> 3/6 编译 Java 源码 (javac)"
find "$WORK/java" "$WORK/gen" -name '*.java' > "$WORK/sources.txt"
# android.jar 里没有 java.lang.invoke.LambdaMetafactory（隐藏类），不能当 -bootclasspath，
# 否则 lambda / 方法引用全部编译不过；放到 classpath 上，与 AGP 的做法一致。
if ! "$JAVAC" -encoding UTF-8 -source 8 -target 8 -nowarn \
  -classpath "$PLATFORM_JAR${CLASSPATH_ARGS:+$PATH_SEP$CLASSPATH_ARGS}" \
  -d "$WORK/classes" \
  @"$WORK/sources.txt" > "$WORK/javac.log" 2>&1; then
  echo "编译失败，javac 输出：" >&2
  cat "$WORK/javac.log" >&2
  exit 1
fi
if [ ! -d "$WORK/classes/com" ]; then
  echo "编译失败：没有生成 class 文件" >&2
  cat "$WORK/javac.log" >&2
  exit 1
fi

echo "==> 4/6 转换 dex (d8)"
# 自己编译出的 class 先打成 jar（d8 对裸目录输入不友好），再和依赖 jar 一起脱糖
"$JAR" cf "$WORK/classes.jar" -C "$WORK/classes" .
"$D8" --release --min-api 21 --lib "$PLATFORM_JAR" \
  --output "$WORK/dex" \
  "$WORK/classes.jar" "${JARS[@]}"

echo "==> 5/6 打包 + 对齐 (classes.dex + zipalign)"
python - "$WORK/unsigned.apk" "$WORK/dex/classes.dex" <<'PY'
import shutil, sys, zipfile
apk, dex = sys.argv[1], sys.argv[2]
tmp = apk + ".tmp"
shutil.copyfile(apk, tmp)
with zipfile.ZipFile(tmp, "a", zipfile.ZIP_DEFLATED) as z:
    z.write(dex, "classes.dex")
shutil.move(tmp, apk)
PY
"$ZIPALIGN" -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"

echo "==> 6/6 签名 (apksigner)"
KS="$ROOT/keystore/debug.keystore"
if [ ! -f "$KS" ]; then
  mkdir -p "$(dirname "$KS")"
  "$KEYTOOL" -genkeypair -v \
    -keystore "$KS" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi
mkdir -p "$OUT_DIR"
# 先签到临时目录再复制过去：既避免 apksigner 对已存在文件的行为差异，
# 也避免在仓库里直接删文件（某些共享盘/回收站策略会拦住删除操作）。
"$APKSIGNER" sign \
  --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias androiddebugkey \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$APKSIGNER" verify "$WORK/signed.apk" >/dev/null
cp -f "$WORK/signed.apk" "$OUT"

ls -lh "$OUT"
echo "完成：$OUT"
