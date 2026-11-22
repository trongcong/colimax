#!/usr/bin/env bash
# Runs the XCUITest suite (UITests/ColimaXUITests.xcodeproj) against a UI-test build of the app.
#
#   scripts/ui-tests.sh
#
# 1. Builds build/ColimaX-UITest.app with -D COLIMAX_UI_TESTING (in-memory Colima / Docker fixtures,
#    separate bundle ID dev.colimax.ColimaX.uitest so it never touches your real preferences).
# 2. Runs the UI tests with xcodebuild. The app is launched with COLIMAX_UI_TEST_FIXTURES=1, so no VM
#    or Docker is needed.
#
# Requirements: Xcode (not only the Command Line Tools). The first run asks to allow the test runner
# to control the computer (System Settings → Privacy & Security → Accessibility / Automation).
# Release builds (scripts/build-app.sh without EXTRA_SWIFT_FLAGS) never contain the fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ColimaX-UITest.app"
APP_DIR="${APP}" \
BUNDLE_ID="dev.colimax.ColimaX.uitest" \
SCRATCH_PATH=".build-uitest" \
EXTRA_SWIFT_FLAGS="-Xswiftc -DCOLIMAX_UI_TESTING" \
  scripts/build-app.sh

RESULTS="build/ui-test-results.xcresult"
rm -rf "${RESULTS}"
LOG="build/ui-tests.log"
set +e
TEST_RUNNER_COLIMAX_UITEST_APP="$(pwd)/${APP}" xcodebuild test -quiet \
  -project UITests/ColimaXUITests.xcodeproj \
  -scheme ColimaXUITests \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/ui-test-derived \
  -resultBundlePath "${RESULTS}" >"${LOG}" 2>&1
STATUS=$?
set -e
# Only the lines that matter: test results and errors (full log in build/ui-tests.log).
grep -E "Test Case|error:|failed|passed|Executed|\*\* TEST" "${LOG}" | grep -v "DVTErrorPresenter\|CoreSimulator" || true
xcrun xcresulttool get test-results summary --path "${RESULTS}" --compact 2>/dev/null \
  | grep -oE '"(result|totalTestCount|passedTests|failedTests|skippedTests|testName|failureText)" *: *("([^"\\]|\\.)*"|[0-9]+)' | awk '!seen[$0]++' || true
# Per-test durations (seconds), to spot slow tests.
xcrun xcresulttool get test-results tests --path "${RESULTS}" --compact 2>/dev/null \
  | grep -oE '"durationInSeconds":[0-9.]+,"name":"test[^"]*"|"name":"test[^"]*"[^}]*"durationInSeconds":[0-9.]+' \
  | sed -E 's/.*"durationInSeconds":([0-9.]+).*"name":"([^"]*)".*/  \2 \1 s/; s/.*"name":"([^"]*)".*"durationInSeconds":([0-9.]+).*/  \1 \2 s/' || true
if [ $STATUS -eq 0 ]; then echo "UI tests passed. Results: ${RESULTS}"; else echo "UI tests FAILED (exit ${STATUS}). Full log: ${LOG}, results: ${RESULTS}" >&2; fi
exit $STATUS
