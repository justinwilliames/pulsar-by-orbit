#!/usr/bin/env bash
# uninstall-hooks.sh — the revert path for the Pulsar DRONE hooks only.
# Removes ONLY the two drone hooks that install-hooks.sh wires:
#
#   • SubagentStart → subagent-start.sh
#   • SubagentStop  → subagent-stop.sh
#
# EVERYTHING ELSE is left untouched — the Stop/SessionStart/UserPromptSubmit
# voice+chime hooks, the statusLine, and any non-Pulsar hooks (claudata,
# delegation-ledger, etc.) that share those two events all survive. Idempotent:
# re-running when the drone hooks are already gone is a clean no-op.
#
# If install-hooks.sh left a backup (settings.json.pulsar-bak.*), we mention
# the most recent one so the user can hand-restore if they want a full revert;
# but the default action is a surgical removal of just the two drone entries,
# not a blanket rollback (which would also nuke unrelated later changes).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBSTART_HOOK="$SCRIPT_DIR/subagent-start.sh"
SUBSTOP_HOOK="$SCRIPT_DIR/subagent-stop.sh"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

if [ ! -f "$SETTINGS" ]; then
  echo "No settings file at $SETTINGS — nothing to uninstall."
  exit 0
fi

# Note the most recent backup (informational only).
LATEST_BAK=""
for b in "$SETTINGS".pulsar-bak.*; do
  [ -f "$b" ] && LATEST_BAK="$b"
done

# Back up the current state before we edit (so THIS removal is also revertible).
cp "$SETTINGS" "$SETTINGS.pulsar-uninstall-bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true

SUBSTART_HOOK="$SUBSTART_HOOK" SUBSTOP_HOOK="$SUBSTOP_HOOK" \
SETTINGS="$SETTINGS" python3 <<'PY'
import json, os

settings_path = os.environ["SETTINGS"]
substart_cmd = os.environ["SUBSTART_HOOK"]
substop_cmd = os.environ["SUBSTOP_HOOK"]

with open(settings_path) as f:
    try:
        data = json.load(f)
    except Exception:
        data = {}

hooks = data.get("hooks", {})

# Also match by trailing script name so a differently-rooted install (a second
# user, a moved repo) is still cleanable — the command path may not equal ours.
def matches(cmd, target_abs):
    if not isinstance(cmd, str):
        return False
    if cmd == target_abs:
        return True
    name = os.path.basename(target_abs)
    return cmd.rstrip("/").endswith("/" + name) or cmd == name

def strip_event(event, target_abs):
    removed = 0
    arr = hooks.get(event)
    if not isinstance(arr, list):
        return 0
    new_groups = []
    for group in arr:
        inner = group.get("hooks", []) if isinstance(group, dict) else []
        kept = [h for h in inner if not matches(h.get("command"), target_abs)]
        removed += len(inner) - len(kept)
        if kept:
            group["hooks"] = kept
            new_groups.append(group)
        elif not isinstance(group, dict) or "hooks" not in group:
            # Preserve anything that isn't a standard hook group untouched.
            new_groups.append(group)
        # else: group's hooks all removed -> drop the now-empty group.
    if new_groups:
        hooks[event] = new_groups
    else:
        hooks.pop(event, None)
    return removed

removed_start = strip_event("SubagentStart", substart_cmd)
removed_stop = strip_event("SubagentStop", substop_cmd)

# Drop the hooks key entirely only if it ended up empty.
if isinstance(data.get("hooks"), dict) and not data["hooks"]:
    data.pop("hooks", None)

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"SubagentStart hook:    {'removed' if removed_start else 'not present'}")
print(f"SubagentStop hook:     {'removed' if removed_stop else 'not present'}")
print(f"Settings:              {settings_path}")
PY

echo
if [ -n "$LATEST_BAK" ]; then
  echo "A pre-install backup exists if you want a full revert instead:"
  echo "  $LATEST_BAK"
fi
echo "Done. The drone hooks are removed; all other hooks and the status line"
echo "are untouched. Start a NEW Claude Code session (or open /hooks) to reload."
