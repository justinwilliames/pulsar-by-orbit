#!/usr/bin/env bash
# session-start-voice.sh — Claude Code SessionStart hook.
#
# Makes the spoken voice MODEL-SIDE and reliable for any install, without
# depending on the user's personal CLAUDE.md or on the skill auto-surfacing.
#
# When the Pulsar daemon is up, it injects a directive (via the SessionStart
# `additionalContext` channel) telling the model to compose + fire a neutral
# say.sh line at the end of every turn. The model is already generating text,
# so composing a line adds no latency and no API key — it rides the user's
# existing Claude Code session.
#
# The directive ADAPTS to the daemon's live settings:
#   • muted        → inject nothing (voice dormant)
#   • cached pings → ON: bespoke is primary, the canon Stop hook is the floor.
#                    OFF: there is no canned fallback, so the user wants to HEAR
#                    a line every turn — instruct bespoke on EVERY turn, never
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

CANON=$(printf '%s' "$SETTINGS" | python3 -c 'import sys,json
try: print("off" if json.load(sys.stdin).get("canon_enabled") is False else "on")
except: print("on")' 2>/dev/null || echo "on")

EXPLETIVES=$(printf '%s' "$SETTINGS" | python3 -c 'import sys,json
try: print("true" if json.load(sys.stdin).get("expletives_enabled") else "false")
except: print("false")' 2>/dev/null || echo "false")

ENGINE=$(printf '%s' "$SETTINGS" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("voice_engine") or "native")
except: print("native")' 2>/dev/null || echo "native")

# Cadence follows the message-style toggle.
if [ "$CANON" = "off" ]; then
  FREE_NOTE=""
  [ "$ENGINE" = "native" ] && FREE_NOTE=" You are on the free local voice — no credits, no limit."
  CADENCE_LINE="The user has turned OFF cached pings: they want to hear a status line on EVERY turn. Compose and fire a fresh line at the end of every single assistant turn — never skip, never go silent; there is no cached fallback now.${FREE_NOTE}"
else
  CADENCE_LINE="This bespoke line is the goal; the cached canon Stop hook is only a fallback for turns you do not speak on (it debounces on recent pings, so there is no double voice)."
fi

# Register flavour: Polite = clean professional; Potty Mouth = same but may include the odd expletive.
if [ "$EXPLETIVES" = "true" ]; then
  REGISTER_NOTE=" Voice register is POTTY MOUTH — the status line MAY include the odd expletive (e.g. \"Pushed, finally.\", \"Tests fucking passing.\", \"Build's done.\"). Still short, still plain, still neutral status — no persona, no \"Sir\". The swearing is the register, not a character."
else
  REGISTER_NOTE=" Voice register is POLITE — keep the status line clean, no profanity."
fi

DIRECTIVE="Voice is ACTIVE this session — the Pulsar app is running. At the END of every assistant turn, optionally emit ONE short, neutral spoken status line reflecting what just happened:
  ${SAY} \"<status line>\"
Keep it plain and present-tense — e.g. \"Tests passing.\", \"Build complete.\", \"Pushed.\", \"Done.\", \"Found it.\". No persona, no \"Sir\", no flourish.${REGISTER_NOTE} ${CADENCE_LINE} Keep each line short — a phrase or one short sentence. Never pass --cacheable on a session-specific line (named files, commits, findings). If the user gives a mute keyword (e.g. \"voice off\", \"mute\"), stop firing for the rest of the session. If say.sh exits non-zero, stay silent that turn."

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
