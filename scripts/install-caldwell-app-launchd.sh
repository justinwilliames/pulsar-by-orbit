#!/bin/sh
# install-caldwell-app-launchd.sh — register Pulsar.app with launchd so
# it auto-starts at every login.

set -e

LABEL="team.yourorbit.Pulsar"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
OLD_LABEL="team.yourorbit.CaldwellDashboard"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
# Legacy Python-daemon LaunchAgent we retire below. This is a DISTINCT,
# now-defunct identifier — it must never equal $LABEL (the live app agent),
# or the retirement block would boot out / disable the app's own agent right
# before we load it. Historically shipped as team.yourorbit.caldwell-speak.
DAEMON_LABEL="team.yourorbit.caldwell-speak-daemon"
DAEMON_PLIST_PATH="$HOME/Library/LaunchAgents/$DAEMON_LABEL.plist"
# Also retire the original legacy daemon label if it's still lingering.
LEGACY_DAEMON_LABEL="team.yourorbit.caldwell-speak"
LEGACY_DAEMON_PLIST_PATH="$HOME/Library/LaunchAgents/$LEGACY_DAEMON_LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"
APP_PATH="/Applications/Pulsar.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/CaldwellDashboard"

if [ ! -x "$EXECUTABLE" ]; then
  echo "Error: $EXECUTABLE not found." >&2
  echo "Run scripts/install-caldwell-app.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

# Migrate away from the old CaldwellDashboard label so both labels are never
# loaded simultaneously. bootout is the modern equivalent of unload.
if launchctl list 2>/dev/null | grep -q "$OLD_LABEL"; then
  echo "Unloading old label $OLD_LABEL..."
  launchctl bootout "$GUI_DOMAIN/$OLD_LABEL" 2>/dev/null || launchctl unload "$OLD_PLIST_PATH" 2>/dev/null || true
fi
if [ -f "$OLD_PLIST_PATH" ]; then
  rm -f "$OLD_PLIST_PATH"
fi

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
  echo "Stopping existing Pulsar.app instance(s) so launchd can manage a single process..."
  pkill -f "$EXECUTABLE" 2>/dev/null || true
  sleep 1
fi

for legacy_label in "$DAEMON_LABEL" "$LEGACY_DAEMON_LABEL"; do
  legacy_plist="$HOME/Library/LaunchAgents/$legacy_label.plist"
  if [ -f "$legacy_plist" ] || launchctl list 2>/dev/null | grep -q "$legacy_label"; then
    echo "Retiring legacy Python daemon LaunchAgent ($legacy_label)..."
    launchctl unload "$legacy_plist" 2>/dev/null || true
    launchctl disable "$GUI_DOMAIN/$legacy_label" 2>/dev/null || true
  fi
done
echo "say.sh now points at the Swift app on http://127.0.0.1:7865"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Loaded $LABEL"
echo "Pulsar.app will auto-launch at every login."
echo ""
echo "To stop and remove:"
echo "  launchctl unload $PLIST_PATH"
echo "  rm $PLIST_PATH"
