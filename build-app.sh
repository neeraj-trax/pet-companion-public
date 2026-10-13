#!/bin/zsh
# Builds Pet.app into ./build. Double-click the result to run it.
set -e
set -o pipefail
cd "$(dirname "$0")"

echo "Compiling…"
swift build -c release 2>&1 | grep -v "^\[" || true
(( pipestatus[1] == 0 )) || { echo "Build failed"; exit 1; }
test -x .build/release/Pet || { echo "Build failed"; exit 1; }

echo "Self-test…"
.build/release/Pet --selftest | grep "^selftest:" || { echo "Self-test failed"; exit 1; }

APP="build/Pet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pet "$APP/Contents/MacOS/Pet"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/pet-dog-atlas.png "$APP/Contents/Resources/pet-dog-atlas.png"

echo "Drawing icon…"
ICONSET="build/Pet.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
.build/release/Pet --render-icon build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Pet.icns"
rm -rf "$ICONSET"

codesign --force --sign - "$APP" 2>/dev/null || true
echo "Done → $APP"
