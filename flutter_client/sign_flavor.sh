#!/usr/bin/env bash
# 对 build_flavor.sh 产出的 APK 做 zipalign + 签名（工程未配置 signingConfig）。
#   ./sign_flavor.sh hd
#   ./sign_flavor.sh regular
# 产物：<项目根>/nascabos-mobile-<flavor>-release-v<code>.apk
#
# 注意：必须用 /Users/ermao/Env/android-signing/nascabos-20261017 这把钥匙，
# 否则无法覆盖升级已安装的正式包。

set -euo pipefail

FLAVOR="${1:-}"
case "$FLAVOR" in
  hd|regular) ;;
  *) echo "用法: $0 <hd|regular>" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"   # -> flutter_client/

BT="/Users/ermao/Env/android-sdk/build-tools/36.0.0"
KS_DIR="/Users/ermao/Env/android-signing/nascabos-20261017"
KS="$KS_DIR/nascabos-release.jks"
ALIAS="nascabos-release"

SRC="build/app/outputs/flutter-apk/app-${FLAVOR}-release.apk"
[ -f "$SRC" ] || { echo "找不到 $SRC，请先运行 ./build_flavor.sh $FLAVOR" >&2; exit 1; }

# versionCode 直接从 APK 读（--build-number 会覆盖 pubspec 里的 +N，以 APK 为准）
VERSION_CODE=$("$BT/aapt" dump badging "$SRC" 2>/dev/null | sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" | head -1)
VERSION_NAME=$("$BT/aapt" dump badging "$SRC" 2>/dev/null | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -1)
OUT="/Users/ermao/GPT/Dokcer/nascabos-mobile-${FLAVOR}-release-v${VERSION_CODE}.apk"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
PW="$(tr -d '\n\r' < "$KS_DIR/keystore-password.txt")"
printf '%s\n%s\n' "$PW" "$PW" > "$WORK/password.txt"
unset PW
chmod 600 "$WORK/password.txt"

echo "==> zipalign"
"$BT/zipalign" -p -f 4 "$SRC" "$WORK/aligned.apk"

echo "==> apksigner"
"$BT/apksigner" sign \
  --ks "$KS" --ks-key-alias "$ALIAS" \
  --ks-pass file:"$WORK/password.txt" --key-pass file:"$WORK/password.txt" \
  --min-sdk-version 24 \
  --out "$OUT" "$WORK/aligned.apk"

echo "==> 校验"
"$BT/apksigner" verify --print-certs "$OUT" | head -6
ls -lh "$OUT"
