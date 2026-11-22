#!/usr/bin/env bash
# Fast build with swiftc directly (no SwiftPM), for environments where SwiftPM cannot run (e.g. a sandbox).
# Prints all warnings/errors; exits non-zero if the build fails, or on any warning when WARNINGS_AS_ERRORS=1 (CI).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/colimax-build}"
mkdir -p "$OUT"
LOG="$OUT/build.log"
set +e
swiftc -disable-sandbox -swift-version 6 -parse-as-library -module-name ColimaX \
  -target arm64-apple-macosx14.0 -module-cache-path "$OUT/module-cache" \
  $(find Sources -name '*.swift') -o "$OUT/ColimaX" >"$LOG" 2>&1
STATUS=$?
set -e
grep -v xcrun_db "$LOG" || true
if [ $STATUS -eq 0 ] && [ "${WARNINGS_AS_ERRORS:-0}" = "1" ] && grep -q "warning:" "$LOG"; then
  echo "Build produced warnings (WARNINGS_AS_ERRORS=1)" >&2
  exit 1
fi
if [ $STATUS -eq 0 ]; then echo "Built $OUT/ColimaX"; fi
exit $STATUS
