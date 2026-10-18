#!/usr/bin/env bash
# 用同一套代码构建两种变体（仅屏幕方向不同）：
#   ./build_flavor.sh hd       -> 大屏版：Pico VR 一体机 / Pad 等高分设备，横屏（landscape）
#                                 使 Pico 分配 1600x900 大屏
#   ./build_flavor.sh regular  -> 普通手机版，竖屏（portrait）
#
# 可用 BUILD_NUMBER 覆盖 versionCode（覆盖安装时新包的 versionCode 必须大于已装包）：
#   BUILD_NUMBER=2062 ./build_flavor.sh hd
#
# 实现方式（标准 AGP）：productFlavors + flavor 专属源集 Manifest 覆盖
#   android/app/src/hd/AndroidManifest.xml       -> screenOrientation=landscape
#   android/app/src/regular/AndroidManifest.xml  -> screenOrientation=portrait
# 主 Manifest（src/main）不声明 screenOrientation，由各 flavor 覆盖注入。
#
# 产物：build/app/outputs/flutter-apk/app-<flavor>-release.apk（未签名，需 zipalign + apksigner）

set -euo pipefail

FLAVOR="${1:-}"
case "$FLAVOR" in
  hd|regular) ;;
  *) echo "用法: $0 <hd|regular>" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"   # -> flutter_client/

export JAVA_HOME="${JAVA_HOME:-/Users/ermao/Env/jdk-21/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/Users/ermao/Env/android-sdk}"
FLUTTER="${FLUTTER:-/Users/ermao/Env/flutter/bin/flutter}"

echo "==> flutter build apk --release --flavor $FLAVOR${BUILD_NUMBER:+ --build-number=$BUILD_NUMBER}"
# --android-skip-build-dependency-validation：本机 Gradle 8.12 < Flutter 要求的 8.14，必带
"$FLUTTER" build apk --release --flavor "$FLAVOR" --android-skip-build-dependency-validation \
  ${BUILD_NUMBER:+--build-number="$BUILD_NUMBER"}

echo "==> 产物: build/app/outputs/flutter-apk/app-${FLAVOR}-release.apk"
