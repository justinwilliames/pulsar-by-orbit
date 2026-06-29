#!/usr/bin/env bash
# chime.sh — Caldwell's turn-end chime for Claude Code. Sound only, no voice,
# no ElevenLabs. The butler's little "that's done, Sir" bell.
#
#   • quick reply  -> soft Tink
#   • long task    -> Hero flourish (paired with turn-start.sh, which stamps
#                     the turn's start so we can tell long from short)
#
# Deliberately INDEPENDENT of the voice mute: chimes are the free, always-on
# cue that still works when you've muted the expensive voice. Silence them on
# their own with:  touch ~/.claude/chime-off   (rm to bring them back).
#
# Wired in by install-hooks.sh as a Stop hook.

[ -f "$HOME/.claude/chime-off" ] && exit 0

input=$(cat 2>/dev/null)
sid=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id // "default"' 2>/dev/null)
[ -z "$sid" ] && sid="default"

stamp="$HOME/.claude/.cc-turn-$sid"
now=$(date +%s)
start=$now
[ -f "$stamp" ] && start=$(cat "$stamp" 2>/dev/null || echo "$now")
rm -f "$stamp" 2>/dev/null
elapsed=$(( now - start ))
[ "$elapsed" -lt 0 ] && elapsed=0

THRESHOLD=45

if [ "$elapsed" -ge "$THRESHOLD" ]; then
  afplay /System/Library/Sounds/Hero.aiff >/dev/null 2>&1 &
else
  afplay /System/Library/Sounds/Tink.aiff >/dev/null 2>&1 &
fi

exit 0
