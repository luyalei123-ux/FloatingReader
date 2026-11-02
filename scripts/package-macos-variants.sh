#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
if [ ! -d "$REPO/dist/macOS-universal/浮读.app" ]; then bash "$REPO/scripts/build-macos.sh" universal; fi
for PAIR in 'x86_64 Intel' 'arm64 AppleSilicon'; do
  read -r ARCH LABEL <<< "$PAIR"
  OUT="$REPO/dist/macOS-$LABEL"
  mkdir -p "$OUT"
  if [ -d "$OUT/浮读.app" ]; then rm -rf "$OUT/浮读.app"; fi
  ditto "$REPO/dist/macOS-universal/浮读.app" "$OUT/浮读.app"
  EXE="$OUT/浮读.app/Contents/MacOS/FloatingReader"
  xcrun lipo "$EXE" -thin "$ARCH" -output "$OUT/reader-thin"
  mv "$OUT/reader-thin" "$EXE"
  codesign --force --sign "${MACOS_SIGN_IDENTITY:--}" "$OUT/浮读.app"
  codesign --verify --strict --verbose=2 "$OUT/浮读.app"
  ditto -c -k --sequesterRsrc --keepParent "$OUT/浮读.app" "$REPO/dist/FloatingReader-macOS-$LABEL.zip"
done
