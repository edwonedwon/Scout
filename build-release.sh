#!/usr/bin/env bash
# Build a standalone macOS Scout.app into ./Release (no Xcode needed to run it).
# Usage: ./build-release.sh
set -euo pipefail

cd "$(dirname "$0")"

echo "▶ Building Scout (Release)…"
xcodebuild -scheme Scout_macOS -configuration Release \
    -derivedDataPath ./Release/DerivedData build

APP="$(find ./Release/DerivedData/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
if [[ -z "$APP" ]]; then
    echo "✗ Build produced no .app" >&2
    exit 1
fi

rm -rf "./Release/$(basename "$APP")"
cp -R "$APP" ./Release/
echo "✓ Built ./Release/$(basename "$APP")"
echo "  Open it with: open ./Release/$(basename "$APP")"
