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

# Replace any existing copy
rm -rf "$DEST"
cp -R "$APP_PATH" "$DEST"

echo ""
echo "✓ Scout.app → $DEST"
echo "  Open with:  open \"$DEST\""
