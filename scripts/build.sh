#!/bin/bash
# 构建 Release 版 Flash.app，并打包为 dist/Flash-<版本>.dmg
# 用法：scripts/build.sh            # 构建 .app 与 .dmg
#       scripts/build.sh --no-dmg   # 只构建 .app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2}' project.yml)"
DIST="$ROOT/dist"
DERIVED="$ROOT/build"
APP_OUT="$DIST/Flash.app"

echo "==> [1/5] 拉取内核（已存在则跳过）"
"$ROOT/scripts/fetch-core.sh"

echo "==> [2/5] 生成 Xcode 工程"
xcodegen generate >/dev/null

echo "==> [3/5] 编译 Release（universal 取决于内核架构，当前为本机架构）"
xcodebuild -project Flash.xcodeproj -scheme Flash -configuration Release \
  -derivedDataPath "$DERIVED" build 2>&1 | { rg "error:|BUILD (SUCCEEDED|FAILED)" || true; }
BUILT="$DERIVED/Build/Products/Release/Flash.app"
[ -d "$BUILT" ] || { echo "构建失败：未找到 $BUILT"; exit 1; }

echo "==> [4/5] 拷贝并签名（ad-hoc）"
rm -rf "$APP_OUT"
mkdir -p "$DIST"
cp -R "$BUILT" "$APP_OUT"
# 注意：不能重新签名 Resources/Core/mihomo，也不能使用 --deep。
# 实测经过 codesign 重签后，macOS 不再允许内核读取其他进程的套接字归属，
# 进程识别（PROCESS-NAME 规则、请求列表的进程列）会失效；保持其原有的链接器签名即可。
codesign --force --sign - --options runtime --entitlements "$ROOT/Flash/Flash.entitlements" "$APP_OUT"
codesign --verify --strict "$APP_OUT" && echo "    签名校验通过"
xattr -dr com.apple.quarantine "$APP_OUT" 2>/dev/null || true

if [ "${1:-}" = "--no-dmg" ]; then
  echo "==> 完成：$APP_OUT"
  exit 0
fi

echo "==> [5/5] 打包 DMG"
DMG="$DIST/Flash-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP_OUT" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
rm -f "$DMG"
hdiutil create -volname "Flash $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "==> 完成：$DMG ($(du -h "$DMG" | cut -f1))"
