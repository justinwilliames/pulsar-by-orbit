#!/usr/bin/env bash
# install-hooks.sh — wire Caldwell's Claude Code hooks into the user's
# ~/.claude/settings.json. Idempotent and non-destructive: it only ADDS the
# two Caldwell hooks if absent and leaves every other hook untouched.
#
#   • Stop          → stop-hook.sh          (cached-canon fallback every turn)
#   • SessionStart  → session-start-voice.sh (injects the bespoke turn-end
#                      voice directive when the daemon is up)
#
# Together these make Caldwell speak model-side: the model composes a fresh
# line each turn (no API key — it rides the user's own Claude Code session),
# with cached canon as the floor. Run once after installing the app.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STOP_HOOK="$SCRIPT_DIR/stop-hook.sh"
SESSION_HOOK="$SCRIPT_DIR/session-start-voice.sh"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

for f in "$STOP_HOOK" "$SESSION_HOOK"; do
  [ -f "$f" ] || { echo "Error: missing hook script $f" >&2; exit 1; }
  chmod +x "$f"
done

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Back up before touching it.
cp "$SETTINGS" "$SETTINGS.caldwell-bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true

STOP_HOOK="$STOP_HOOK" SESSION_HOOK="$SESSION_HOOK" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, sys

settings_path = os.environ["SETTINGS"]
stop_cmd = os.environ["STOP_HOOK"]
session_cmd = os.environ["SESSION_HOOK"]

with open(settings_path) as f:
    try:
        data = json.load(f)
    except Exception:
        data = {}

hooks = data.setdefault("hooks", {})

def ensure(event, command, timeout):
    arr = hooks.setdefault(event, [])
    # Already present anywhere in this event's groups?
    for group in arr:
        for h in group.get("hooks", []):
            if h.get("command") == command:
                return False
    arr.append({"matcher": "", "hooks": [
        {"type": "command", "command": command, "timeout": timeout}
    ]})
    return True

added_stop = ensure("Stop", stop_cmd, 5)
added_session = ensure("SessionStart", session_cmd, 5)

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"Stop hook:          {'added' if added_stop else 'already present'}")
print(f"SessionStart hook:  {'added' if added_session else 'already present'}")
print(f"Settings:           {settings_path}")
PY

echo
echo "Done. Start a NEW Claude Code session for the voice directive to take effect."
echo "Caldwell will compose a bespoke line each turn while the app is running."
