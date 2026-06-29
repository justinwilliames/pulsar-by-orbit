#!/usr/bin/env bash
# stop-hook.sh — Claude Code Stop event handler.
#
# Picks a context-appropriate Tier 0 canon line and asks the daemon to play
# it — cache-only, no ElevenLabs spend. Stays silent on any of these:
#
#   1. Daemon unreachable
#   2. Daemon mute is on (Sir AFK)
#   3. Skill already fired in the last 60s (don't double up)
#   4. Context detected but no cached canon matches it (daemon returns 204)
#
# Context comes from grepping the last assistant message in the Claude Code
# transcript for tells like "pushed", "tests pass", "build failed", "found",
# etc. The Stop hook receives a JSON event on stdin with `transcript_path`.
#
# Stop hooks block Claude Code until they exit, so this is built to be
# fast (<100ms typical) and silent (all output redirected to /dev/null).

set -e

DAEMON="http://127.0.0.1:7865"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAY="$SCRIPT_DIR/say.sh"

# Read the Stop event from stdin (best-effort — older Claude Code versions
# may not send anything). 2s timeout so a missing producer can't hang us.
EVENT_JSON=""
if [ -t 0 ]; then
  : # tty — nothing to read
else
  EVENT_JSON=$(timeout 2 cat 2>/dev/null || true)
fi

# 1. Daemon up?
curl -sf --connect-timeout 1 "$DAEMON/health" >/dev/null 2>&1 || exit 0

# 2. Pull /settings once — check muted state
SETTINGS=$(curl -sf --connect-timeout 1 "$DAEMON/settings" 2>/dev/null || echo "{}")
MUTED=$(echo "$SETTINGS" | python3 -c 'import sys,json
try: print("true" if json.load(sys.stdin).get("muted") else "false")
except: print("false")' 2>/dev/null || echo "false")

# Muted? Full silent mode — no ElevenLabs calls, no Tier 0 fallback
[ "$MUTED" = "true" ] && exit 0

# 3. Is anything currently playing or queued? If so, the skill already
#    fired this turn — don't stack a hook ping on top.
#    /queue returns {playing: Bool, queued: Int, ...}; we treat either
#    as "busy" and back off.
BUSY=$(curl -sf --connect-timeout 1 "$DAEMON/queue" 2>/dev/null \
  | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
    busy = bool(d.get("playing")) or int(d.get("queued", 0)) > 0
    print("busy" if busy else "idle")
except: print("idle")' 2>/dev/null || echo "idle")
[ "$BUSY" = "busy" ] && exit 0

# 4. Recent COMPLETED ping in the last 60 seconds? Skill fired and
#    finished — still back off to avoid double-pings on close turns.
#    NOTE: /history returns a bare JSON array, not {"entries":[…]}.
#    Earlier code assumed an object and silently failed → no debounce.
RECENT=$(curl -sf --connect-timeout 1 "$DAEMON/history?limit=1" 2>/dev/null \
  | python3 -c 'import sys,json,time
try:
    d = json.load(sys.stdin)
    entries = d if isinstance(d, list) else d.get("entries", [])
    if not entries:
        print("none")
    else:
        ts = entries[0].get("timestamp", 0)
        print("recent" if (time.time() - ts) < 60 else "stale")
except: print("none")' 2>/dev/null || echo "none")
[ "$RECENT" = "recent" ] && exit 0

# 5. Detect context from the last assistant message in the transcript.
#    Falls back to "neutral" if no transcript path or no tells matched.
CONTEXT="neutral"
TRANSCRIPT_PATH=""
if [ -n "$EVENT_JSON" ]; then
  TRANSCRIPT_PATH=$(echo "$EVENT_JSON" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("transcript_path",""))
except: print("")' 2>/dev/null || echo "")
fi

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Pull the last assistant text content. Read tail to stay fast on big
  # transcripts. Detection runs in lowercase; bash globbing handles substrings.
  LAST_TEXT=$(tail -c 200000 "$TRANSCRIPT_PATH" 2>/dev/null | python3 -c '
import sys, json
last = ""
for raw in sys.stdin:
    raw = raw.strip()
    if not raw or not raw.startswith("{"): continue
    try:
        ev = json.loads(raw)
    except: continue
    if ev.get("type") != "assistant": continue
    msg = ev.get("message", {})
    for chunk in msg.get("content", []):
        if chunk.get("type") == "text":
            text = chunk.get("text", "")
            if text: last = text
print(last.lower()[-4000:])
' 2>/dev/null || echo "")

  # High precision, low recall: only fire a SPECIFIC context when the closing
  # message clearly signals it. Everything else falls through to "neutral" —
  # which the daemon now treats as a dedicated generic-acknowledgement pool,
  # not the union of every context. So a missed match costs a safe neutral
  # line ("Done."), never an irrelevant specific ("Tests passing.").
  #
  # Success is matched BEFORE failure so "fixed the failed test" reads as
  # done, not a fresh cock-up. Failure tells are deliberately strict — a
  # wrongly-fired "Cocked it up, Sir." is the most jarring miss of the lot.
  # There is no "start" case: this hook runs at turn-END, where "on it /
  # I'll take a look" lines are backwards (the work is already finished).
  case "$LAST_TEXT" in
    *"force-push"*|*"force pushed"*|*"pushed to"*|*" pushed,"*|*" pushed."*|*"git push"*)
      CONTEXT="push" ;;
    *"tests pass"*|*"tests are passing"*|*"tests passing"*|*"all tests pass"*|*"all green"*|*"test suite pass"*)
      CONTEXT="tests-pass" ;;
    *"build's clean"*|*"build is clean"*|*"build succe"*|*"build complete"*|*"compiled clean"*)
      CONTEXT="build-pass" ;;
    *"found it"*|*"found the bug"*|*"located the"*|*"spotted the"*|*"root cause is"*|*"that's the culprit"*)
      CONTEXT="found" ;;
    *"all sorted"*|*"that's sorted"*|*"shipped"*|*"merged"*|*" done."*|*"all set"*|*"ready to ship"*|*"that's done"*)
      CONTEXT="done" ;;
    *"still failing"*|*"still broken"*|*"that didn't work"*|*"couldn't get it"*|*"no joy"*|*"won't compile"*|*"still red"*)
      CONTEXT="fail" ;;
    *)
      CONTEXT="neutral" ;;
  esac
fi

# 6. Fire the daemon's canon picker with the detected context.
#    Cache-only — if no cached canon matches this context, daemon returns
#    204 and we stay silent rather than spend ElevenLabs credit on a guess.
"$SAY" --canon "$CONTEXT" >/dev/null 2>&1 || true

exit 0
