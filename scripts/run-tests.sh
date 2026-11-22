#!/usr/bin/env bash
# Builds and runs the whole XCTest suite with swiftc (no SwiftPM needed).
#   scripts/run-tests.sh                 # unit tests (integration tests are skipped)
#   scripts/run-tests.sh --integration   # also run integration tests against real Colima/Docker
#                                        # (COLIMAX_PROFILE=<profile>, default "default")
# Where a full SwiftPM toolchain is available, `swift test` works too.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--integration" ]; then export COLIMAX_INTEGRATION=1; fi

OUT="${OUT_DIR:-${TMPDIR:-/tmp}/colimax-tests}"
mkdir -p "$OUT"
DEV="$(xcode-select -p)"
FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
# XCTest.framework loads XCTestCore and friends from PrivateFrameworks (Xcode 26+); add both to the rpath.
PRIVATE_FW="$DEV/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks"
LIB="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"

# Exclude the app's @main file; the runner has its own @main.
SOURCES=$(find Sources -name '*.swift' ! -name 'ColimaXApp.swift')
TESTS=$(find Tests/ColimaXTests -name '*.swift')

set +e
swiftc -disable-sandbox -swift-version 6 -parse-as-library -module-name ColimaXTestBundle -D COLIMAX_UI_TESTING \
  -target arm64-apple-macosx14.0 -module-cache-path "$OUT/module-cache" \
  -F "$FW" -I "$LIB" -L "$LIB" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$PRIVATE_FW" -Xlinker -rpath -Xlinker "$LIB" \
  $SOURCES $TESTS Tests/Runner/main.swift -o "$OUT/run-tests" >"$OUT/build.log" 2>&1
STATUS=$?
set -e
grep -v xcrun_db "$OUT/build.log" || true
[ $STATUS -eq 0 ] || { echo "Test build failed"; exit $STATUS; }

"$OUT/run-tests"
