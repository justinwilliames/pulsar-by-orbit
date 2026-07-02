#!/usr/bin/env bash
# turn-start.sh — Pulsar plumbing. Stamps when a turn starts, per session,
# so chime.sh can tell a long task from a quick reply and ring the right bell.
# Tiny and silent. Wired in by install-hooks.sh as a UserPromptSubmit hook.

input=$(cat 2>/dev/null)
sid=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id // "default"' 2>/dev/null)
[ -z "$sid" ] && sid="default"
date +%s > "$HOME/.claude/.cc-turn-$sid" 2>/dev/null
exit 0
