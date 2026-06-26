#!/bin/bash
# build_mac.sh — builds the macOS Scout app (Debug, ad-hoc signed) without opening Xcode.
# Output: ~/Applications/Scout.app  (or pass a custom path as $1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${1:-/Applications}"
BUILD_DIR="$PROJECT_ROOT/.build/mac"

echo "▶ Building Scout (macOS, Debug)…"

xcodebuild \
    -project "$PROJECT_ROOT/Scout.xcodeproj" \
    -scheme Scout_macOS \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM=2J8M8Z4QCX \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \

APP_PATH=$(find "$BUILD_DIR/Build/Products/Debug" -maxdepth 1 -name "*.app" | head -1)

if [ -z "$APP_PATH" ]; then
    echo "✗ Build succeeded but .app not found in $BUILD_DIR/Build/Products/Debug"
    exit 1
fi

mkdir -p "$OUT_DIR"
DEST="$OUT_DIR/Scout.app"

# Quit ANY running Scout before swapping the bundle. A bare `open` on an already-running
# app only re-focuses the old process — macOS won't reload a new binary into it — so without
# this you'd keep testing a stale build. Graceful quit first, then force-kill stragglers.
# The path match (…Scout.app/Contents/MacOS/Scout) covers both the /Applications copy and
# any instance launched from Xcode's DerivedData.
echo "▶ Quitting any running Scout…"
osascript -e 'tell application "Scout" to quit' >/dev/null 2>&1 || true
# Give it a moment to exit cleanly, then force-kill whatever's left.
for _ in 1 2 3 4 5; do
    pgrep -f "Scout.app/Contents/MacOS/Scout" >/dev/null 2>&1 || break
    sleep 0.3
done
pkill -9 -f "Scout.app/Contents/MacOS/Scout" >/dev/null 2>&1 || true

# Replace any existing copy
rm -rf "$DEST"
cp -R "$APP_PATH" "$DEST"

echo ""
echo "✓ Scout.app → $DEST"
echo "▶ Launching fresh build…"
open "$DEST"
