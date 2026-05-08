#!/bin/sh
# install-launchd.sh — register the Caldwell daemon with launchd so it
# auto-starts at login and restarts if it crashes.
#
# Generates a fresh plist using the current shell's paths (no template
# substitution), copies it to ~/Library/LaunchAgents, loads it.
#
# Reads the daemon at $REPO_ROOT/daemon/server.py and uses `uv` from
# the current PATH. Logs go to $REPO_ROOT/logs/daemon.{out,err}.log.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="team.yourorbit.caldwell-speak"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$REPO_ROOT/logs"

UV_BIN="$(command -v uv || true)"
if [ -z "$UV_BIN" ]; then
  echo "Error: uv not found in PATH." >&2
  echo "Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  echo "Then re-run this script." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
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
        <string>$UV_BIN</string>
        <string>run</string>
        <string>$REPO_ROOT/daemon/server.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$REPO_ROOT</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/daemon.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/daemon.err.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

# Reload (unload first if already present; ignore errors from a not-loaded state)
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Loaded $LABEL"
echo "Daemon running at http://127.0.0.1:7865"
echo "Logs: $LOG_DIR/daemon.out.log, $LOG_DIR/daemon.err.log"
echo ""
echo "To check status:    launchctl list | grep caldwell-speak"
echo "To stop:            scripts/uninstall-launchd.sh"
