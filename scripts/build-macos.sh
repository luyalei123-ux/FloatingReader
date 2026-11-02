#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:-universal}
case "$TARGET" in
  universal) ARCHS="x86_64 arm64"; LABEL=universal ;;
  x86_64) ARCHS=x86_64; LABEL=Intel ;;
  arm64) ARCHS=arm64; LABEL=AppleSilicon ;;
  *) echo 'Usage: bash scripts/build-macos.sh [universal|x86_64|arm64]' >&2; exit 2 ;;
esac
VERSION=$(cat "$REPO/VERSION")
OUT="$REPO/dist/macOS-$LABEL"
mkdir -p "$OUT"
BUILD=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/浮读.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in $ARCHS; do
  xcrun swiftc "$REPO/macos/Sources/main.swift" -module-cache-path "$BUILD/ModuleCache-$ARCH" \
    -o "$BUILD/reader-$ARCH" -framework AppKit -framework WebKit -framework Vision \
    -target "$ARCH-apple-macosx12.0" -O
done
if [ "$TARGET" = universal ]; then
  xcrun lipo -create "$BUILD/reader-x86_64" "$BUILD/reader-arm64" -output "$APP/Contents/MacOS/FloatingReader"
else
  cp "$BUILD/reader-$TARGET" "$APP/Contents/MacOS/FloatingReader"
fi
cp "$REPO/macos/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
cp "$REPO/macos/Resources/reader.js" "$APP/Contents/Resources/"
cp "$REPO/macos/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$REPO/macos/Resources/Icons" "$APP/Contents/Resources/"
cp "$REPO/LICENSE" "$REPO/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/MacOS/FloatingReader"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign "${MACOS_SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict --verbose=2 "$APP"
xcrun lipo -archs "$APP/Contents/MacOS/FloatingReader"
if [ -d "$OUT/浮读.app" ]; then rm -rf "$OUT/浮读.app"; fi
mv "$APP" "$OUT/浮读.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$OUT/浮读.app" "$REPO/dist/FloatingReader-macOS-$LABEL.zip"
echo "Built: dist/FloatingReader-macOS-$LABEL.zip"
