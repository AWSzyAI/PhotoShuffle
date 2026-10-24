#!/bin/zsh
set -eu
ROOT="${0:A:h}"
CACHE="${TMPDIR:-/tmp}/photo-shuffle-swift-cache"
MODE="${1:-}"
if [[ -n "$MODE" && "$MODE" != --universal ]]; then print -u2 '用法：zsh build.sh [--universal]'; exit 2; fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/photo-shuffle-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/照片随放.app"
OUT="$ROOT/build/照片随放.app"
print '[1/5] 准备临时构建目录与应用图标'
mkdir -p "$CACHE" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK/AppIcon.iconset" "$ROOT/build"
cp "$ROOT/assets/icon.png" "$WORK/icon.png"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE*2))
  sips -z "$DOUBLE" "$DOUBLE" "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
python3 "$ROOT/make-icon.py" "$WORK/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
print '[2/5] 编译 macOS 13+ 应用'
HOST="$(uname -m)"
ARCHES=("$HOST")
if [[ "$MODE" == --universal ]]; then ARCHES=(arm64 x86_64); fi
for ARCH in "${ARCHES[@]}"; do
  print "  正在编译 $ARCH"
  swiftc -swift-version 5 -O -target "${ARCH}-apple-macosx13.0" -module-cache-path "$CACHE" "$ROOT/PhotoShuffle.swift" -o "$WORK/PhotoShuffle-$ARCH" -framework AppKit -framework Photos -framework CoreGraphics -framework ServiceManagement
done
print '[3/5] 运行当前机器架构的纯逻辑自检（无需图库权限）'
"$WORK/PhotoShuffle-$HOST" --self-test
if [[ "$MODE" == --universal ]]; then
  lipo -create "$WORK/PhotoShuffle-arm64" "$WORK/PhotoShuffle-x86_64" -output "$APP/Contents/MacOS/PhotoShuffle"
else
  cp "$WORK/PhotoShuffle-$HOST" "$APP/Contents/MacOS/PhotoShuffle"
fi
print '[4/5] 在临时目录清理元数据、本地签名并严格验签'
xattr -cr "$APP"
codesign --force --sign - --entitlements "$ROOT/Entitlements.plist" "$APP"
codesign --verify --strict --verbose=2 "$APP"
print '[5/5] 导出成品'
# Cloud-backed source folders can reattach Finder metadata; packaging revalidates off-cloud.
rm -rf "$OUT"
ditto --noextattr --norsrc "$APP" "$OUT"
lipo -archs "$APP/Contents/MacOS/PhotoShuffle"
print "完成：$OUT"
