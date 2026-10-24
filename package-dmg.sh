#!/bin/zsh
set -eu
ROOT="${0:A:h}"
APP="$ROOT/build/照片随放.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")
if [[ ! -d "$APP" ]]; then print -u2 '请先执行 zsh build.sh --universal'; exit 1; fi
ARCHES="$(lipo -archs "$APP/Contents/MacOS/PhotoShuffle")"
if [[ "$ARCHES" == *arm64* && "$ARCHES" == *x86_64* ]]; then FLAVOR=universal; else FLAVOR="$ARCHES"; fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/photo-shuffle-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DMG="$ROOT/dist/PhotoShuffle-${VERSION}-${FLAVOR}.dmg"
print '[1/4] 将应用复制到本地临时目录'
mkdir -p "$WORK/stage" "$ROOT/dist"
ditto --noextattr --norsrc "$APP" "$WORK/stage/照片随放.app"
print '[2/4] 清理云盘元数据并重新签名、验签'
xattr -cr "$WORK/stage/照片随放.app"
codesign --force --sign - --entitlements "$ROOT/Entitlements.plist" "$WORK/stage/照片随放.app"
codesign --verify --strict --verbose=2 "$WORK/stage/照片随放.app"
ln -s /Applications "$WORK/stage/Applications"
cp "$ROOT/INSTALL.txt" "$WORK/stage/安装说明.txt"
print '[3/4] 制作压缩 DMG（拖入 Applications 安装）'
hdiutil create -volname "照片随放 ${VERSION}" -srcfolder "$WORK/stage" -format UDZO -ov "$WORK/output.dmg"
hdiutil verify "$WORK/output.dmg"
cp "$WORK/output.dmg" "$DMG"
print '[4/4] 生成 SHA-256 校验文件'
(cd "$ROOT/dist" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
cat "$DMG.sha256"
print "完成：$DMG"
