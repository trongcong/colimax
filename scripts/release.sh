#!/usr/bin/env bash
# Produces a complete release: test -> build (Developer ID) -> notarize app -> DMG -> notarize DMG -> checksum.
# Does not publish anything: artifacts land in build/; create the GitHub Release by hand or via the release workflow.
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=colimax scripts/release.sh
#
# Optional: BUILD_NUMBER, BUNDLE_ID, SKIP_TESTS=1 (only when CI already ran the tests in an earlier step).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
export VERSION
: "${SIGN_IDENTITY:?SIGN_IDENTITY must be a Developer ID Application certificate (releases cannot be signed ad-hoc)}"
[ "$SIGN_IDENTITY" != "-" ] || { echo "Releases must not be signed ad-hoc" >&2; exit 1; }

# The version must have a CHANGELOG entry.
grep -q "^## \[${VERSION}\]" CHANGELOG.md || { echo "CHANGELOG.md has no [${VERSION}] entry" >&2; exit 1; }

if [ "${SKIP_TESTS:-0}" != "1" ]; then
  echo "== Unit test"
  scripts/run-tests.sh
fi

echo "== Build ${VERSION}"
scripts/build-app.sh

echo "== Notarize app"
scripts/notarize.sh build/ColimaX.app

echo "== DMG"
scripts/make-dmg.sh

echo "== Notarize DMG"
scripts/notarize.sh "build/ColimaX-${VERSION}.dmg"
shasum -a 256 "build/ColimaX-${VERSION}.dmg" | awk '{print $1}' > "build/ColimaX-${VERSION}.dmg.sha256"

echo
echo "Ready to release:"
echo "  build/ColimaX-${VERSION}.dmg"
echo "  build/ColimaX-${VERSION}.dmg.sha256  ($(cat "build/ColimaX-${VERSION}.dmg.sha256"))"
echo "Next: git tag v${VERSION} && git push origin v${VERSION}, then create the GitHub Release (see docs/RELEASE.md)."
