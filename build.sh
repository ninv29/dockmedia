#!/bin/bash
# Builds DockMedia.app into ./build. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
APP=build/DockMedia.app

swift build -c release --arch arm64 2>&1 | grep -vE "^(\[|Building|Compiling|Write|Linking|Planning)" || true
BIN=$(swift build -c release --arch arm64 --show-bin-path)/DockMedia
test -x "$BIN"

mkdir -p build
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch arm64e -framework Foundation \
  Helper/MediaRemoteHelper.m -o build/MediaRemoteHelper.dylib

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DockMedia"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/MediaRemoteHelper.dylib "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/MenuBarIconTemplate.png Resources/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/"

# Sign with a stable identity when available so macOS permissions (Accessibility)
# survive rebuilds; fall back to ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
IDENTITY=${IDENTITY:--}
codesign --force -s "$IDENTITY" "$APP/Contents/Resources/MediaRemoteHelper.dylib"
codesign --force -s "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x DockMedia 2>/dev/null || true
  rm -rf /Applications/DockMedia.app
  cp -R "$APP" /Applications/
  open /Applications/DockMedia.app
  echo "Installed to /Applications/DockMedia.app"
fi
