#!/bin/zsh
# Build a shareable Pet.dmg with the dog atlas.
set -e
set -o pipefail
cd "$(dirname "$0")"

./build-app.sh

DMG_ROOT="$(mktemp -d /private/tmp/pet-dmg.XXXXXX)"
SHARE_APP="$DMG_ROOT/Pet.app"
DMG="build/Pet.dmg"
trap 'rm -rf "$DMG_ROOT"' EXIT

rm -rf build/dmg-root "$DMG"
# The project lives in a synced Documents folder. Stage outside it so macOS
# does not add Finder/file-provider attributes that invalidate the app seal.
ditto --noextattr --noqtn build/Pet.app "$SHARE_APP"
test -s "$SHARE_APP/Contents/Resources/pet-dog-atlas.png"
test ! -e "$SHARE_APP/Contents/Resources/pet-atlas.webp"
xattr -cr "$SHARE_APP"
ln -s /Applications "$DMG_ROOT/Applications"

# Sign the shareable copy after clearing extended attributes.
# A Developer ID identity can replace "-" later for warning-free external distribution.
codesign --force --deep --sign - "$SHARE_APP"
codesign --verify --deep --strict "$SHARE_APP"

hdiutil create -volname "Pet" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign - "$DMG"
hdiutil verify "$DMG" >/dev/null

echo "Done → $DMG (dog artwork included; private robot atlas excluded)"
