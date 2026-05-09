#!/usr/bin/env bash
# stop-hook.sh — Claude Code Stop event handler.
#
# Ensures Caldwell speaks at every turn-end. Fires a random Tier 0
# canonical phrase (cached, free) UNLESS one of these applies:
#
#   1. Daemon unreachable — exit silent, can't speak anyway
#   2. Daemon mute is on — Sir's gone full silent (AFK), respect it
#   3. The skill already fired in the last 60s — don't double up
#
# Stop hooks block Claude Code until they exit, so this is built to be
# fast (<100ms typical) and silent (all output redirected to /dev/null).

set -e

DAEMON="http://127.0.0.1:7865"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAY="$SCRIPT_DIR/say.sh"

# 1. Daemon up?
curl -sf --connect-timeout 1 "$DAEMON/health" >/dev/null 2>&1 || exit 0

# 2. Pull /settings once — check muted AND persona mode in one trip
SETTINGS=$(curl -sf --connect-timeout 1 "$DAEMON/settings" 2>/dev/null || echo "{}")
MUTED=$(echo "$SETTINGS" | python3 -c 'import sys,json
try: print("true" if json.load(sys.stdin).get("muted") else "false")
except: print("false")' 2>/dev/null || echo "false")
POTTY=$(echo "$SETTINGS" | python3 -c 'import sys,json
try: print("true" if json.load(sys.stdin).get("expletives_enabled") else "false")
except: print("false")' 2>/dev/null || echo "false")

# Muted? Full silent mode — no ElevenLabs calls, no Tier 0 fallback
[ "$MUTED" = "true" ] && exit 0

# 3. Recent /speak in the last 60 seconds? skill fired, hook backs off
RECENT=$(curl -sf --connect-timeout 1 "$DAEMON/history?limit=1" 2>/dev/null \
  | python3 -c 'import sys,json,time
try:
    d = json.load(sys.stdin)
    entries = d.get("entries", [])
    if not entries: print("none")
    else:
        ts = entries[0].get("timestamp", 0)
        print("recent" if (time.time() - ts) < 60 else "stale")
except: print("none")' 2>/dev/null || echo "none")
[ "$RECENT" = "recent" ] && exit 0

# 4. Pick a random Tier 0 phrase from the persona-appropriate pool.
# Mode-neutral canon — works in both Polite and Potty Mouth modes.
PHRASES=(
  "Right then Sir."
  "Right then Sir, on it."
  "On it, Sir."
  "Onto it."
  "Quite, Sir."
  "Sorted, Sir."
  "Sorted."
  "Most kind, Sir."
  "Most regrettable, Sir."
  "I'll have a look."
  "Tests passing."
  "Build's clean."
  "Pushed, Sir."
  "Bit of a faff, that."
  "Found it, Sir."
)

# When Potty Mouth is on, blend in profane canon at ~40% rate so Sir
# actually hears the dial. Keep the polite phrases in too — Caldwell's
# RP cadence is the bit; expletives are flavor, not every line.
if [ "$POTTY" = "true" ]; then
  PHRASES+=(
    "Fuckin' pushed."
    "Sorted, fuckin' done."
    "Tests fuckin' passing."
    "Right then Sir, fuckin' on it."
    "Bloody hell, Sir."
    "Bollocks."
    "Cocked it up, Sir."
    "Sweet fuck-all to worry about, Sir."
    "Bloody well done, that."
    "Job's a good 'un, Sir."
  )
fi

PHRASE="${PHRASES[$RANDOM % ${#PHRASES[@]}]}"

# Fire — say.sh queues to daemon and returns immediately. Pass --cacheable
# so the daemon writes to phrase cache on first miss; subsequent fires of
# the same phrase replay free.
"$SAY" "$PHRASE" --cacheable >/dev/null 2>&1 || true

exit 0
