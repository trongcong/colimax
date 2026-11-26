#!/bin/sh
# Installs ColimaX from GitHub Releases into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/trongcong/colimax/main/scripts/install.sh | sh
#
# What it does, and nothing else:
#   1. picks the newest release (pre-releases included) or COLIMAX_VERSION, e.g. 1.0.0-beta.2;
#   2. downloads ColimaX-<version>.dmg and its .sha256 with curl and checks the SHA-256 (this only
#      catches a broken download: the .sha256 comes from the same release page as the DMG);
#   3. if the GitHub CLI is installed and signed in, verifies the build provenance: the DMG must have
#      been built by this repository's Release workflow from tag v<version>. A failed check stops the
#      install (COLIMAX_ALLOW_UNVERIFIED=1 overrides it, e.g. for 1.0.0-beta.1, built by hand);
#   4. copies ColimaX.app from the DMG into COLIMAX_APP_DIR (default /Applications), replacing an
#      older ColimaX.app there.
#
# Builds are ad-hoc signed and not notarized by Apple yet. Files downloaded with curl are not
# quarantined by macOS, so Gatekeeper does not prompt before the first launch: you are trusting the
# trongcong/colimax GitHub repository and its releases. Read this script before running it; it needs
# no sudo and touches nothing outside the app folder and a temporary directory.
set -eu
# The whole script is one function called on the last line, so a download cut off midway by
# `curl | sh` runs nothing instead of half a script.
main() {
# Keep code lines ASCII-only: with a non-UTF-8 locale, sh may read a non-ASCII byte right after $VAR
# as part of the variable name ("VERSION...: unbound variable").

REPO="trongcong/colimax"
APP_NAME="ColimaX.app"
APP_DIR="${COLIMAX_APP_DIR:-/Applications}"
VERSION="${COLIMAX_VERSION:-}"

[ "$(uname -s)" = "Darwin" ] || fail "ColimaX runs on macOS only."
[ "$(uname -m)" = "arm64" ] || fail "ColimaX needs a Mac with Apple Silicon (arm64)."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] || fail "ColimaX needs macOS 14 or later (this Mac: $(sw_vers -productVersion))."
[ -d "$APP_DIR" ] || fail "$APP_DIR does not exist."
[ -w "$APP_DIR" ] || fail "$APP_DIR is not writable by $(id -un). Set COLIMAX_APP_DIR=\$HOME/Applications to install there."
# Canonical path (no trailing slash, symlinks such as /var -> /private/var resolved), so messages are
# clean and the running-app check below matches the path macOS reports for the process.
APP_DIR="$(cd "$APP_DIR" && pwd -P)"

if [ -z "$VERSION" ]; then
  # Newest published release first; the API does not list drafts to anonymous callers.
  TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1" \
    | plutil -extract 0.tag_name raw -o - - 2>/dev/null)" \
    || fail "Could not find the latest release of $REPO (offline, or the GitHub API rate limit of 60 requests per hour was hit). Set COLIMAX_VERSION=<version> to skip this lookup."
  VERSION="${TAG#v}"
fi
case "$VERSION" in
  *[!0-9A-Za-z.-]*|"") fail "Invalid version: $VERSION" ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/colimax-install.XXXXXX")"
MOUNT="$WORK/mnt"
cleanup() {
  [ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

DMG="ColimaX-$VERSION.dmg"
BASE="https://github.com/$REPO/releases/download/v$VERSION"
say "Downloading ColimaX ${VERSION}..."
curl -fL --progress-bar -o "$WORK/$DMG" "$BASE/$DMG" || fail "Download failed: $BASE/$DMG"
curl -fsSL -o "$WORK/$DMG.sha256" "$BASE/$DMG.sha256" || fail "Download failed: $BASE/$DMG.sha256"

EXPECTED="$(awk '{print $1}' "$WORK/$DMG.sha256")"
ACTUAL="$(shasum -a 256 "$WORK/$DMG" | awk '{print $1}')"
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || fail "SHA-256 mismatch (expected $EXPECTED, got $ACTUAL)."
say "SHA-256 OK: $ACTUAL"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  set -- "$WORK/$DMG" -R "$REPO"
  # Pin the signer workflow and the tag when this gh version supports it.
  if gh attestation verify --help 2>/dev/null | grep -q -- '--signer-workflow'; then
    set -- "$@" --signer-workflow "$REPO/.github/workflows/release.yml" --source-ref "refs/tags/v$VERSION"
  fi
  if gh attestation verify "$@" >/dev/null 2>&1; then
    say "Build provenance OK: built by the Release workflow of $REPO from tag v$VERSION."
  elif [ "${COLIMAX_ALLOW_UNVERIFIED:-0}" = "1" ]; then
    say "Warning: build provenance NOT verified; continuing because COLIMAX_ALLOW_UNVERIFIED=1."
  else
    fail "Build provenance check failed for $DMG. Do not install it unless you know why (releases built by hand, such as 1.0.0-beta.1, have none). To install anyway: COLIMAX_ALLOW_UNVERIFIED=1"
  fi
else
  say "Note: build provenance not checked (install the GitHub CLI and run 'gh auth login' to check it)."
fi

# Only the copy being replaced matters; another ColimaX (e.g. in a different folder) can keep running.
if pgrep -f "$APP_DIR/$APP_NAME/Contents/MacOS/" >/dev/null 2>&1; then
  fail "ColimaX in $APP_DIR is running. Quit it (ColimaX menu > Quit ColimaX), then run this script again."
fi

mkdir "$MOUNT"
hdiutil attach "$WORK/$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" -quiet || fail "Could not open $DMG."
[ -d "$MOUNT/$APP_NAME" ] || fail "$APP_NAME not found in $DMG."

# Copy next to the old app first, then swap with two renames, so a failed copy or move never leaves
# you without ColimaX; the old copy is removed last.
NEW="$APP_DIR/.$APP_NAME.new"
OLD="$APP_DIR/.$APP_NAME.old"
rm -rf "$NEW" "$OLD"
ditto "$MOUNT/$APP_NAME" "$NEW" || { rm -rf "$NEW"; fail "Could not copy $APP_NAME into $APP_DIR (disk full?)."; }
if [ -e "$APP_DIR/$APP_NAME" ]; then mv "$APP_DIR/$APP_NAME" "$OLD"; fi
if ! mv "$NEW" "$APP_DIR/$APP_NAME"; then
  [ -e "$OLD" ] && mv "$OLD" "$APP_DIR/$APP_NAME"
  fail "Could not move the new app into $APP_DIR."
fi
rm -rf "$OLD"

say "Installed ColimaX $VERSION in $APP_DIR/$APP_NAME."
say "Open it from your Applications folder or run: open \"$APP_DIR/$APP_NAME\""
}

say() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

main "$@"
