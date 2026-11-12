#!/bin/bash
#
# 把 SPM 产物组装成一个可双击运行的 macOS 应用包。
# 用法：Scripts/build.sh [debug|release]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="Lens"
BIN_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "▸ 编译（${CONFIG}）"
# --disable-sandbox：某些受限环境（CI、沙箱）里 SwiftPM 自带的 sandbox-exec 会失效。
swift build -c "${CONFIG}" --disable-sandbox

echo "▸ 准备图标"
ICNS="$ROOT/Resources/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
    TMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$TMP_ICONSET"
    swift "$ROOT/Scripts/make_icon.swift" "$TMP_ICONSET/icon-1024.png" >/dev/null

    for pair in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
                "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
                "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
        px="${pair%%:*}"
        name="${pair##*:}"
        sips -z "$px" "$px" "$TMP_ICONSET/icon-1024.png" --out "$TMP_ICONSET/$name.png" >/dev/null 2>&1
    done
    rm -f "$TMP_ICONSET/icon-1024.png"

    iconutil -c icns "$TMP_ICONSET" -o "$ICNS"
    echo "  已生成 $ICNS"
else
    echo "  复用已有 $ICNS"
fi

echo "▸ 组装 app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "▸ ad-hoc 签名"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 \
    && echo "  已签名" \
    || echo "  签名失败（不影响本机运行）"

echo ""
echo "✓ 完成：$APP_DIR"
echo "  运行：open \"$APP_DIR\""
