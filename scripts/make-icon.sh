#!/usr/bin/env bash
# Generates Resources/AppIcon.icns and Resources/AppIcon-1024.png from scripts/make-icon.swift
# (drawn with CoreGraphics; no external assets or iconutil needed).
# To use a designer-made icon instead, replace both files in Resources/ and skip this script.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${TMPDIR:-/tmp}/colimax-icon"
mkdir -p "$WORK" Resources
swiftc -disable-sandbox -module-cache-path "$WORK/module-cache" scripts/make-icon.swift -o "$WORK/make-icon" 2>&1 | grep -v xcrun_db || true
"$WORK/make-icon" Resources/AppIcon.icns Resources/AppIcon-1024.png
