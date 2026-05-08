#!/bin/sh
# build-caldwell-app.sh — compile the SwiftUI menu-bar app and assemble
# a proper Caldwell.app bundle.
#
# Requires macOS 26 (Tahoe) — the app uses Liquid Glass APIs that don't
# exist on earlier macOS versions.
# Requires Swift 6.1+ — bundled with macOS 26.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/macos/CaldwellDashboard"
BUILD_DIR="$APP_DIR/build"
APP_BUNDLE="$BUILD_DIR/Caldwell.app"

# macOS version sanity check
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 26 ]; then
  echo "Error: this app requires macOS 26 (Tahoe) or later." >&2
  echo "Current macOS: $(sw_vers -productVersion)" >&2
  echo "Use Plash or the web dashboard until you upgrade." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Error: swift not found. Install Xcode or Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

cd "$APP_DIR"

echo "Building release binary (this can take a minute)..."
swift build -c release

BINARY="$APP_DIR/.build/release/CaldwellDashboard"
if [ ! -f "$BINARY" ]; then
  # Apple Silicon may put it under a triple-prefixed dir
  BINARY="$(find "$APP_DIR/.build" -name CaldwellDashboard -type f -path "*/release/*" 2>/dev/null | head -1)"
fi

if [ ! -f "$BINARY" ]; then
  echo "Error: build did not produce a CaldwellDashboard binary under .build/" >&2
  exit 1
fi

echo "Assembling Caldwell.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/CaldwellDashboard"
cp "$APP_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc sign so Gatekeeper allows local launches without warnings
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "Built: $APP_BUNDLE"
echo "To install:  $SCRIPT_DIR/install-caldwell-app.sh"
echo "To run now:  open '$APP_BUNDLE'"
