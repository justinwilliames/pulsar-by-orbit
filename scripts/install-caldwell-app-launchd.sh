#!/bin/sh
# install-caldwell-app-launchd.sh — register Caldwell.app with launchd so
# it auto-starts at every login.

set -e

LABEL="team.yourorbit.CaldwellDashboard"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
DAEMON_LABEL="team.yourorbit.caldwell-speak"
DAEMON_PLIST_PATH="$HOME/Library/LaunchAgents/$DAEMON_LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"
APP_PATH="/Applications/Caldwell.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/CaldwellDashboard"

if [ ! -x "$EXECUTABLE" ]; then
  echo "Error: $EXECUTABLE not found." >&2
  echo "Run scripts/install-caldwell-app.sh first." >&2
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
    <string>/tmp/caldwell-dashboard.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/caldwell-dashboard.log</string>
</dict>
</plist>
EOF

if pgrep -f "$EXECUTABLE" >/dev/null 2>&1; then
  echo "Stopping existing Caldwell.app instance(s) so launchd can manage a single process..."
  pkill -f "$EXECUTABLE" 2>/dev/null || true
  sleep 1
fi

if [ -f "$DAEMON_PLIST_PATH" ] || launchctl list 2>/dev/null | grep -q "$DAEMON_LABEL"; then
  echo "Retiring legacy Python daemon LaunchAgent ($DAEMON_LABEL)..."
  launchctl unload "$DAEMON_PLIST_PATH" 2>/dev/null || true
  launchctl disable "$GUI_DOMAIN/$DAEMON_LABEL" 2>/dev/null || true
  echo "say.sh now points at the Swift app on http://127.0.0.1:7865"
fi

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Loaded $LABEL"
echo "Caldwell.app will auto-launch at every login."
echo ""
echo "To stop and remove:"
echo "  launchctl unload $PLIST_PATH"
echo "  rm $PLIST_PATH"
