#!/bin/bash
# Build helper for Scout. Builds the macOS and/or iOS targets and reports only
# errors + the final BUILD result, so it's fast to scan.
#
#   ./build.sh            # build both macOS and iOS
#   ./build.sh mac        # build macOS only
#   ./build.sh ios        # build iOS only
#   ./build.sh gen        # regenerate the Xcode project (xcodegen), then build both
#
# Exit status is non-zero if any requested build fails.
set -uo pipefail
cd "$(dirname "$0")"

IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro'
MAC_DEST='platform=macOS'
RESULT=0

build_one() {
  local scheme="$1" dest="$2" label="$3"
  echo "▶︎ Building $label …"
  local out
  out=$(xcodebuild -project Scout.xcodeproj -scheme "$scheme" -destination "$dest" build 2>&1)
  echo "$out" | grep -E "error:|warning: .*deprecated|BUILD (SUCCEEDED|FAILED)" | grep -v "^$" | tail -40
  if echo "$out" | grep -q "BUILD SUCCEEDED"; then
    echo "✅ $label OK"
  else
    echo "❌ $label FAILED"
    RESULT=1
  fi
  echo ""
}

case "${1:-both}" in
  gen) xcodegen generate && build_one Scout_macOS "$MAC_DEST" macOS && build_one Scout_iOS "$IOS_DEST" iOS ;;
  mac) build_one Scout_macOS "$MAC_DEST" macOS ;;
  ios) build_one Scout_iOS "$IOS_DEST" iOS ;;
  both|*) build_one Scout_macOS "$MAC_DEST" macOS; build_one Scout_iOS "$IOS_DEST" iOS ;;
esac

exit $RESULT
