#!/usr/bin/env bash
# Submits a .app or .dmg to Apple for notarization, waits for the result, then staples the ticket.
#   scripts/notarize.sh build/ColimaX.app
#   scripts/notarize.sh build/ColimaX-1.0.0.dmg
#
# Authentication (pick ONE):
#   Dev machine:  NOTARY_PROFILE=<profile created with `xcrun notarytool store-credentials`>
#   CI:           NOTARY_KEY_PATH=<.p8 file>  NOTARY_KEY_ID=<Key ID>  NOTARY_ISSUER_ID=<Issuer ID>
set -euo pipefail

TARGET="${1:?Path to a .app or .dmg is required}"
[ -e "$TARGET" ] || { echo "Not found: $TARGET" >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  echo "Missing notarytool credentials (NOTARY_PROFILE or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID)" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/colimax-notary.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# notarytool accepts .zip/.dmg/.pkg: zip a .app with ditto to preserve the signature and xattrs.
SUBMIT="$TARGET"
if [ -d "$TARGET" ]; then
  SUBMIT="$WORK/$(basename "$TARGET").zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

echo "Submitting for notarization: $TARGET (this may take a few minutes)..."
xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --output-format json > "$WORK/result.json"
STATUS="$(/usr/bin/plutil -extract status raw -o - "$WORK/result.json" 2>/dev/null || echo unknown)"
ID="$(/usr/bin/plutil -extract id raw -o - "$WORK/result.json" 2>/dev/null || echo "")"

if [ "$STATUS" != "Accepted" ]; then
  echo "Notarization failed: status=$STATUS id=$ID" >&2
  [ -n "$ID" ] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# Assess the result the way Gatekeeper will on a user's Mac.
if [ -d "$TARGET" ]; then
  spctl --assess --type execute --verbose=2 "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
echo "Notarized and stapled: $TARGET"
