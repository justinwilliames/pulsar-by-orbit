#!/usr/bin/env bash
# chime.sh — Caldwell's turn-end chime for Claude Code. Sound only, no voice.
#
# DEFERS TO CALDWELL: if the daemon is up AND not muted, voice speaks this
# turn and IS the cue — the chime stays silent so the two never clash. The
# chime only rings when voice won't: when muted, or the app is closed.
# So you get exactly one turn-end cue, never both: unmuted -> voice;
# muted/closed -> a chime.
#
#   • quick reply  -> soft Tink
#   • long task    -> Hero flourish (paired with turn-start.sh, which stamps the
#                     turn's start so we can tell long from short)
#
# Silence the chime on its own too:  touch ~/.claude/chime-off   (rm to restore).
#
# Wired in by install-hooks.sh as a Stop hook.

[ -f "$HOME/.claude/chime-off" ] && exit 0

# Defer to Caldwell's voice. Daemon up AND not muted => he'll speak => no chime.
# Read .muted literally: only an explicit "false" (unmuted) defers. "true",
# "null", or no daemon all fall through and ring. (Don't use `.muted // true` —
# jq's // coalesces false to the fallback, which inverts the test.)
s=$(curl -sf --max-time 1 http://127.0.0.1:7865/settings 2>/dev/null)
if [ -n "$s" ]; then
  m=$(printf '%s' "$s" | /usr/bin/jq -r '.muted' 2>/dev/null)
  [ "$m" = "false" ] && exit 0
fi

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
