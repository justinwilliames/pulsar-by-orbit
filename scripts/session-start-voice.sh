#!/usr/bin/env bash
# session-start-voice.sh — Claude Code SessionStart hook.
#
# Makes Caldwell's voice MODEL-SIDE and reliable for any install, without
# depending on the user's personal CLAUDE.md or on the skill auto-surfacing.
#
# When the Caldwell daemon is up, it injects a directive (via the SessionStart
# `additionalContext` channel) telling the model to compose + fire a BESPOKE
# say.sh line at the end of every turn. The model is already generating text,
# so composing a line adds no latency and no API key — it rides the user's
# existing Claude Code session ("model-side, via Claude Code").
#
# The directive ADAPTS to the daemon's live settings:
#   • muted        → inject nothing (voice dormant)
#   • persona mode → match Polite / Potty Mouth register
#   • cached pings → ON: bespoke is primary, the canon Stop hook is the floor.
#                    OFF: there is no canned fallback, so the user wants to HEAR
#                    Caldwell every turn — instruct bespoke on EVERY turn, never
#                    skip. On the free local voice that's unlimited, so lean in.
#
# App-gated: when the daemon is down (or muted), this injects NOTHING. Fast and
# silent on failure so it can't slow session start.

set -e

DAEMON="http://127.0.0.1:7865"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAY="$SCRIPT_DIR/say.sh"

# Daemon up? If not, stay dormant — emit nothing.
curl -sf --connect-timeout 1 "$DAEMON/health" >/dev/null 2>&1 || exit 0

# One settings fetch; parse everything from it.
SETTINGS=$(curl -sf --connect-timeout 1 "$DAEMON/settings" 2>/dev/null || echo "{}")

MUTED=$(printf '%s' "$SETTINGS" | python3 -c 'import sys,json
try: print("true" if json.load(sys.stdin).get("muted") else "false")
except: print("false")' 2>/dev/null || echo "false")
[ "$MUTED" = "true" ] && exit 0

EXPLETIVES=$(printf '%s' "$SETTINGS" | python3 -c 'import sys,json
try: print("on" if json.load(sys.stdin).get("expletives_enabled") else "off")
except: print("on")' 2>/dev/null || echo "on")

CANON=$(printf '%s' "$SETTINGS" | python3 -c 'import sys,json
try: print("off" if json.load(sys.stdin).get("canon_enabled") is False else "on")
except: print("on")' 2>/dev/null || echo "on")

ENGINE=$(printf '%s' "$SETTINGS" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("voice_engine") or "elevenlabs")
except: print("elevenlabs")' 2>/dev/null || echo "elevenlabs")

if [ "$EXPLETIVES" = "on" ]; then
  MODE_LINE="Persona mode: Potty Mouth — heavy, unflinching expletives are the bit; lean in."
else
  MODE_LINE="Persona mode: Polite — same dry RP cadence, no swearing."
fi

# Cadence follows the message-style toggle.
if [ "$CANON" = "off" ]; then
  FREE_NOTE=""
  [ "$ENGINE" = "native" ] && FREE_NOTE=" You're on the free local voice — no credits, no limit — so speak freely."
  CADENCE_LINE="The user has turned OFF cached pings: they want to hear you on EVERY turn. Compose and fire a fresh bespoke line at the end of every single assistant turn — never skip, never go silent; there is no cached fallback now.${FREE_NOTE}"
else
  CADENCE_LINE="This bespoke line is the goal; the cached canon Stop hook is only a fallback for turns you don't speak on (it debounces on recent pings, so there is no double voice)."
fi

DIRECTIVE="Caldwell voice is ACTIVE this session — the Caldwell app is running. At the END of every assistant turn, compose and fire ONE short, in-character Caldwell line reacting to what actually just happened:
  ${SAY} \"<your bespoke line>\"
Compose a FRESH, specific line by default — name the thing that happened and land the dry RP wit or the expletive. ${CADENCE_LINE} Keep each line short — a phrase or one sentence, not a paragraph. Never pass --cacheable on a session-specific line (named files, commits, findings). ${MODE_LINE} If the user gives a mute keyword (e.g. \"voice off\", \"mute Caldwell\"), stop firing for the rest of the session. If say.sh exits non-zero, stay silent that turn."

# Emit as SessionStart additionalContext (JSON on stdout). Pass the directive
# via stdin so multi-line text with quotes can't be mangled by the shell.
printf '%s' "$DIRECTIVE" | python3 -c 'import json,sys
ctx = sys.stdin.read()
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx
    }
}))'

exit 0
