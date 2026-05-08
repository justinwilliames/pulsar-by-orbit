#!/bin/sh
# uninstall-launchd.sh — unload and remove the Caldwell daemon launchd plist.

set -e

LABEL="team.yourorbit.caldwell-speak"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST_PATH" ]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm "$PLIST_PATH"
  echo "Unloaded and removed $LABEL"
else
  echo "$LABEL not installed (no plist at $PLIST_PATH)"
fi
