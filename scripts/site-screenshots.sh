#!/usr/bin/env bash
# Takes the landing page screenshots (site/img/*.png) from the demo fixtures, so no real container,
# project or path ever appears on the public page.
#
#   scripts/site-screenshots.sh              # every screenshot
#   scripts/site-screenshots.sh monitoring   # only the named ones
#
# For each screenshot the script launches build/ColimaX-UITest.app with COLIMAX_UI_TEST_SCENARIO=demo
# on the right screen, waits for it to settle, then asks you to click the ColimaX window
# (`screencapture -w`). The first run asks for Screen Recording permission for your terminal.
# Keep the window at its default size (1100 × 700) so the images match.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ColimaX-UITest.app"
OUT="site/img"
RAW="$(mktemp -d)"
trap 'rm -rf "$RAW"' EXIT

# name | screen | seconds to wait | container to select (demo key) | caption for the prompt
SHOTS=(
  "containers|containers|4|db|Containers with the db details (secrets masked)"
  "dashboard|dashboard|20||Dashboard (waits for two VM samples)"
  "monitoring|monitoring|75||Monitoring (waits for the charts to fill)"
  "diagnostics|diagnostics|8||Diagnostics and security audit"
)

echo "Building the UI-test app with the demo fixtures…"
APP_DIR="$APP" BUNDLE_ID="dev.colimax.ColimaX.uitest" SCRATCH_PATH=".build-uitest" \
  EXTRA_SWIFT_FLAGS="-Xswiftc -DCOLIMAX_UI_TESTING" scripts/build-app.sh >/dev/null

mkdir -p "$OUT"
for shot in "${SHOTS[@]}"; do
  IFS='|' read -r name screen wait focus caption <<<"$shot"
  if [ $# -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi

  echo
  echo "== $name: $caption"
  env COLIMAX_UI_TEST_FIXTURES=1 COLIMAX_UI_TEST_SCENARIO=demo COLIMAX_UI_TEST_SCREEN="$screen" \
      ${focus:+COLIMAX_UI_TEST_FOCUS="$focus" COLIMAX_UI_TEST_DETAIL_TAB=Info} \
      "$APP/Contents/MacOS/ColimaX" -theme light -AppleLanguages "(en)" -AppleLocale en_US >/dev/null 2>&1 &
  PID=$!
  sleep "$wait"
  echo "   Click the ColimaX window to capture it (Esc skips)."
  ERR="$(screencapture -o -w -x "$RAW/$name.png" 2>&1 || true)"
  if [[ "$ERR" == *"could not create image"* ]]; then
    kill "$PID" 2>/dev/null || true
    echo "   macOS refused the capture: the app running this script has no Screen Recording permission." >&2
    echo "   Allow it in System Settings → Privacy & Security → Screen & System Audio Recording," >&2
    echo "   quit and reopen that app, then run the script again." >&2
    exit 1
  fi
  if [ -s "$RAW/$name.png" ]; then
    # 2× retina capture scaled to 2200 px wide: sharp on high-density screens, about 300–600 KB.
    sips -Z 2200 "$RAW/$name.png" --out "$OUT/$name.png" >/dev/null
    echo "   Saved $OUT/$name.png"
  else
    echo "   Skipped"
  fi
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
done

echo
echo "Done. Review the images in $OUT/ before committing."
