#!/bin/sh
# install-caldwell-app.sh — build the app and copy it to /Applications/.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$REPO_ROOT/macos/CaldwellDashboard/build/Pulsar.app"
TARGET="/Applications/Pulsar.app"

# Build first
"$SCRIPT_DIR/build-caldwell-app.sh"

if [ -d "$TARGET" ]; then
  echo "Removing existing $TARGET ..."
  rm -rf "$TARGET"
fi

cp -R "$APP_BUNDLE" "$TARGET"

# Strip quarantine attribute since the bundle isn't notarised
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo ""
echo "Installed: $TARGET"
echo ""
echo "To launch:    open -a Pulsar"
echo "Auto-launch:  $SCRIPT_DIR/install-caldwell-app-launchd.sh"
