#!/bin/sh
# install-pulsar-app-launchd.sh — register Pulsar.app with launchd so
# it auto-starts at every login.

set -e

LABEL="team.yourorbit.Pulsar"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"
APP_PATH="/Applications/Pulsar.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/Pulsar"

if [ ! -x "$EXECUTABLE" ]; then
  echo "Error: $EXECUTABLE not found." >&2
  echo "Run scripts/install-pulsar-app.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXECUTABLE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/pulsar-dashboard.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/pulsar-dashboard.log</string>
</dict>
</plist>
EOF

if pgrep -f "$EXECUTABLE" >/dev/null 2>&1; then
  echo "Stopping existing Pulsar.app instance(s) so launchd can manage a single process..."
  pkill -f "$EXECUTABLE" 2>/dev/null || true
  sleep 1
fi

echo "say.sh now points at the Swift app on http://127.0.0.1:7865"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Loaded $LABEL"
echo "Pulsar.app will auto-launch at every login."
echo ""
echo "To stop and remove:"
echo "  launchctl unload $PLIST_PATH"
echo "  rm $PLIST_PATH"
