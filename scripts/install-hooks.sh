#!/usr/bin/env bash
# install-hooks.sh — wire Caldwell's Claude Code hooks into the user's
# ~/.claude/settings.json. Idempotent and non-destructive: it only ADDS the
# two Caldwell hooks if absent and leaves every other hook untouched.
#
#   • Stop            → stop-hook.sh           (cached-canon voice fallback)
#   • Stop            → chime.sh               (free turn-end sound, no voice)
#   • SessionStart    → session-start-voice.sh (bespoke turn-end voice directive)
#   • UserPromptSubmit→ turn-start.sh          (stamps turn start for chime.sh)
#   • statusLine      → statusline.sh          (Caldwell's persona-aware bar)
#
# Together these make Caldwell speak model-side (the model composes a fresh
# line each turn — no API key, it rides the user's own Claude Code session,
# with cached canon as the floor) AND give the session a Caldwell-themed
# status line plus a free sound chime when a turn ends. Run once after
# installing the app. Idempotent — safe to re-run.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STOP_HOOK="$SCRIPT_DIR/stop-hook.sh"
SESSION_HOOK="$SCRIPT_DIR/session-start-voice.sh"
CHIME_HOOK="$SCRIPT_DIR/chime.sh"
TURNSTART_HOOK="$SCRIPT_DIR/turn-start.sh"
STATUSLINE="$SCRIPT_DIR/statusline.sh"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

for f in "$STOP_HOOK" "$SESSION_HOOK" "$CHIME_HOOK" "$TURNSTART_HOOK" "$STATUSLINE"; do
  [ -f "$f" ] || { echo "Error: missing hook script $f" >&2; exit 1; }
  chmod +x "$f"
done

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Back up before touching it.
cp "$SETTINGS" "$SETTINGS.caldwell-bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true

STOP_HOOK="$STOP_HOOK" SESSION_HOOK="$SESSION_HOOK" CHIME_HOOK="$CHIME_HOOK" \
TURNSTART_HOOK="$TURNSTART_HOOK" STATUSLINE="$STATUSLINE" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, sys

settings_path = os.environ["SETTINGS"]
stop_cmd = os.environ["STOP_HOOK"]
session_cmd = os.environ["SESSION_HOOK"]
chime_cmd = os.environ["CHIME_HOOK"]
turnstart_cmd = os.environ["TURNSTART_HOOK"]
statusline_cmd = os.environ["STATUSLINE"]

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
added_chime = ensure("Stop", chime_cmd, 5)
added_turnstart = ensure("UserPromptSubmit", turnstart_cmd, 5)

# statusLine is a top-level object, not a hook. Set it only if absent or if it
# already points at a Caldwell statusline script — never clobber a custom one.
sl = data.get("statusLine")
if not sl:
    data["statusLine"] = {"type": "command", "command": statusline_cmd,
                          "refreshInterval": 30, "padding": 0}
    sl_status = "added"
elif str(sl.get("command", "")).endswith("statusline.sh"):
    if sl.get("command") != statusline_cmd:
        sl["command"] = statusline_cmd
        sl_status = "updated"
    else:
        sl_status = "already present"
else:
    sl_status = "left as-is (custom status line present)"

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"Stop hook (voice):     {'added' if added_stop else 'already present'}")
print(f"Stop hook (chime):     {'added' if added_chime else 'already present'}")
print(f"SessionStart hook:     {'added' if added_session else 'already present'}")
print(f"UserPromptSubmit hook: {'added' if added_turnstart else 'already present'}")
print(f"statusLine:            {sl_status}")
print(f"Settings:              {settings_path}")
PY

echo
echo "Done. Start a NEW Claude Code session (or open /hooks once) so the new"
echo "hooks and status line load. Caldwell will compose a bespoke line each turn"
echo "while the app is running, ring a chime when a turn ends, and fly his own"
echo "status line up top."
