#!/usr/bin/env bash
# Builds a release binary (arm64) and packages it as build/ColimaX.app.
#
# Environment:
#   SIGN_IDENTITY   "-" (default, ad-hoc signing) or "Developer ID Application: Name (TEAMID)"
#   BUNDLE_ID       default dev.colimax.ColimaX
#   VERSION         default read from the VERSION file
#   BUILD_NUMBER    default 1 (CI should pass a monotonically increasing number)
#   APP_DIR         default build/ColimaX.app
#   EXTRA_SWIFT_FLAGS  extra `swift build` arguments (scripts/ui-tests.sh passes the UI-test define)
#   SCRATCH_PATH    SwiftPM build directory, default .build
#
# App Sandbox is off (the app must run colima/limactl and read ~/.colima/*/docker.sock);
# Hardened Runtime is on, with no entitlements.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="ColimaX"
# Override with your organization's reverse-DNS for distribution: BUNDLE_ID=com.example.ColimaX
BUNDLE_ID="${BUNDLE_ID:-dev.colimax.ColimaX}"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_DIR="${APP_DIR:-build/ColimaX.app}"
SCRATCH_PATH="${SCRATCH_PATH:-.build}"
# shellcheck disable=SC2206
EXTRA=(${EXTRA_SWIFT_FLAGS:-})

swift build -c release --arch arm64 --scratch-path "${SCRATCH_PATH}" ${EXTRA[@]+"${EXTRA[@]}"}
BIN_PATH="$(swift build -c release --arch arm64 --scratch-path "${SCRATCH_PATH}" ${EXTRA[@]+"${EXTRA[@]}"} --show-bin-path)/${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
else
  echo "Warning: Resources/AppIcon.icns is missing (run scripts/make-icon.sh)" >&2
fi
# Asset catalog icon (Assets.car + CFBundleIconName): recent macOS takes the icon shown in Notification
# Center and other system UI from the asset catalog; the .icns stays as a fallback for older systems.
ICON_NAME_KEY=""
if [ -f Resources/AppIcon-1024.png ] && xcrun --find actool >/dev/null 2>&1; then
  XCASSETS_WORK="$(mktemp -d "${TMPDIR:-/tmp}/colimax-xcassets.XXXXXX")"
  ICONSET="${XCASSETS_WORK}/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "${ICONSET}"
  printf '{"info":{"version":1,"author":"xcode"}}' > "${XCASSETS_WORK}/Assets.xcassets/Contents.json"
  IMAGES=""
  for SIZE in 16 32 128 256 512; do
    sips -z "${SIZE}" "${SIZE}" Resources/AppIcon-1024.png --out "${ICONSET}/icon_${SIZE}.png" >/dev/null
    sips -z "$((SIZE * 2))" "$((SIZE * 2))" Resources/AppIcon-1024.png --out "${ICONSET}/icon_${SIZE}@2x.png" >/dev/null
    IMAGES="${IMAGES}{\"idiom\":\"mac\",\"size\":\"${SIZE}x${SIZE}\",\"scale\":\"1x\",\"filename\":\"icon_${SIZE}.png\"},"
    IMAGES="${IMAGES}{\"idiom\":\"mac\",\"size\":\"${SIZE}x${SIZE}\",\"scale\":\"2x\",\"filename\":\"icon_${SIZE}@2x.png\"},"
  done
  printf '{"images":[%s],"info":{"version":1,"author":"xcode"}}' "${IMAGES%,}" > "${ICONSET}/Contents.json"
  if xcrun actool "${XCASSETS_WORK}/Assets.xcassets" --compile "${APP_DIR}/Contents/Resources" \
       --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
       --output-partial-info-plist "${XCASSETS_WORK}/partial.plist" >"${XCASSETS_WORK}/actool.log" 2>&1 \
     && [ -f "${APP_DIR}/Contents/Resources/Assets.car" ]; then
    ICON_NAME_KEY="<key>CFBundleIconName</key><string>AppIcon</string>"
    rm -rf "${XCASSETS_WORK}"   # kept only on failure, for the actool log
  else
    echo "Warning: actool failed; using AppIcon.icns only (log: ${XCASSETS_WORK}/actool.log)" >&2
  fi
else
  echo "Note: actool (Xcode) not found; using AppIcon.icns only" >&2
fi
# Localization (G18): keys are the English strings in code; translations live in Resources/<lang>.lproj.
for LPROJ in Resources/*.lproj; do
  [ -d "${LPROJ}" ] && cp -R "${LPROJ}" "${APP_DIR}/Contents/Resources/"
done

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ColimaX</string>
    <key>CFBundleDisplayName</key><string>ColimaX</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    ${ICON_NAME_KEY}
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>vi</string></array>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 ColimaX contributors. MIT License.</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Hardened Runtime, no entitlements. Developer ID signing needs a secure timestamp for notarization.
if [ "${SIGN_IDENTITY}" = "-" ]; then
  codesign --force --options runtime --sign - "${APP_DIR}"
  echo "Signed ad-hoc (local use only; Gatekeeper will block it on other Macs)."
else
  codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}"
fi
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "Created ${APP_DIR} (version ${VERSION}, build ${BUILD_NUMBER}, bundle ${BUNDLE_ID})"
echo "Run:       open ${APP_DIR}"
echo "Install:   cp -R ${APP_DIR} /Applications/"
