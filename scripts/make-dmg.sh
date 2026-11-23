#!/usr/bin/env bash
# Packages build/ColimaX.app as build/ColimaX-<version>.dmg (drag-and-drop into Applications).
#   SIGN_IDENTITY  if not "-", the DMG is signed too (required before notarizing the DMG)
#   DMG_TOOL       hdiutil | diskutil (default: diskutil on macOS 26+, hdiutil before)
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
VOLNAME="ColimaX ${VERSION}"

# `hdiutil create` is deprecated from macOS 26; `diskutil image` replaces it there but does not exist
# on older systems. DMG_TOOL=hdiutil|diskutil overrides the choice.
if [ -z "${DMG_TOOL:-}" ]; then
  if [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]; then DMG_TOOL=diskutil; else DMG_TOOL=hdiutil; fi
fi

case "$DMG_TOOL" in
  hdiutil)
    hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    ;;
  diskutil)
    # diskutil has no -srcfolder: create a blank read-write image, copy the files in,
    # then convert it to a compressed read-only image.
    RAW="$STAGE.raw.dmg"
    MNT="$STAGE.mnt"
    DISK=""
    cleanup_diskutil() {
      [ -z "$DISK" ] || diskutil eject "$DISK" >/dev/null 2>&1 || true
      rm -rf "$RAW" "$MNT"
    }
    trap 'cleanup_diskutil; rm -rf "$STAGE"' EXIT

    # App size + 20% + 16 MB headroom for APFS metadata.
    SIZE_KB=$(( $(du -sk "$STAGE" | awk '{print $1}') * 12 / 10 + 16384 ))
    diskutil image create blank --format RAW --size "${SIZE_KB}k" --volumeName "$VOLNAME" -fs APFS "$RAW" >/dev/null
    ATTACH_OUT="$(diskutil image attach --nobrowse --mountPoint "$MNT" "$RAW")"
    DISK="$(printf '%s\n' "$ATTACH_OUT" | grep -oE 'disk[0-9]+' | head -n 1)"
    [ -n "$DISK" ] || { echo "Could not read the disk identifier from: $ATTACH_OUT" >&2; exit 1; }

    ditto "$STAGE/ColimaX.app" "$MNT/ColimaX.app"
    ln -s /Applications "$MNT/Applications"

    diskutil eject "$DISK" >/dev/null
    DISK=""
    # Its progress lines go to stderr; show the output only if the conversion fails.
    CONVERT_OUT="$(diskutil image create from --format UDZO "$RAW" "$DMG" 2>&1)" \
      || { printf '%s\n' "$CONVERT_OUT" >&2; exit 1; }
    ;;
  *)
    echo "DMG_TOOL must be hdiutil or diskutil (got: $DMG_TOOL)" >&2
    exit 1
    ;;
esac

if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"
echo "Created $DMG"
echo "SHA-256: $(cat "$DMG.sha256")"
