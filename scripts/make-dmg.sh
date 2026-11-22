#!/usr/bin/env bash
# Packages build/ColimaX.app as build/ColimaX-<version>.dmg (drag-and-drop into Applications).
#   SIGN_IDENTITY  if not "-", the DMG is signed too (required before notarizing the DMG)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ColimaX.app"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
DMG="build/ColimaX-${VERSION}.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

[ -d "$APP" ] || { echo "Missing $APP; run scripts/build-app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/colimax-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "ColimaX ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"
echo "Created $DMG"
echo "SHA-256: $(cat "$DMG.sha256")"
