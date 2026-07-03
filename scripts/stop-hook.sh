#!/usr/bin/env bash
# stop-hook.sh — Claude Code Stop event handler.
#
# Picks a context-appropriate fallback canon line and asks the daemon to play
# it — this is the FLOOR, only for turns the model didn't compose a bespoke
# line on. Bespoke is the default; this just stops a silent turn-end. Stays
# silent on any of these:
#
#   1. Daemon unreachable
#   2. Daemon mute is on (Sir AFK)
#   3. Skill already fired in the last 60s (don't double up / talk over a line)
#   4. Context detected but no cached canon matches it (daemon returns 204)
#
# Context comes from grepping the last assistant message in the Claude Code
# transcript for tells like "pushed", "tests pass", "build failed", "found",
# etc. The Stop hook receives a JSON event on stdin with `transcript_path`.
#
# Stop hooks block Claude Code until they exit, so this is built to be
# fast (<100ms typical) and silent (all output redirected to /dev/null).

# Recursion guard — the Missions titler (turn-start.sh) invokes `claude` with
# hooks disabled to generate a session name; if that ever leaks, this env flag
# set on the naming sub-run keeps its Stop from creating a stray "waiting"
# mission (or looping). No-op the whole hook for the naming invocation.
[ -n "$PULSAR_NAMING" ] && exit 0

set -e

DAEMON="http://127.0.0.1:7865"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAY="$SCRIPT_DIR/say.sh"

# Read the Stop event from stdin (best-effort — older Claude Code versions
# may not send anything). The `[ -t 0 ]` guard handles the no-producer case;
# stdin is a pipe Claude Code closes after writing, so a plain `cat` can't
# hang. (Do NOT use `timeout` here — it does not exist on macOS, so
# `timeout 2 cat` silently returns empty, which nukes session_id and stops
# the Missions board from ever flipping a session to "Paused".)
EVENT_JSON=""
if [ -t 0 ]; then
  : # tty — nothing to read
else
  EVENT_JSON=$(cat 2>/dev/null || true)
fi

# 1. Daemon up?
curl -sf --connect-timeout 1 "$DAEMON/health" >/dev/null 2>&1 || exit 0

# 1b. Missions board: the turn just ENDED, so this session is now waiting on the
#     user ("Needs you"). Signal phase:"waiting" — NO user_message (only a real
#     UserPromptSubmit moves the recency window). Best-effort, backgrounded,
#     non-fatal, and fired regardless of the mute/busy/debounce backoffs below so
#     the board's status is always accurate. Parses session_id/cwd from the Stop
#     event JSON already read into EVENT_JSON above.
if [ -n "$EVENT_JSON" ]; then
  S_SID=$(printf '%s' "$EVENT_JSON" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("session_id",""))
except: print("")' 2>/dev/null || echo "")
  S_CWD=$(printf '%s' "$EVENT_JSON" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("cwd",""))
except: print("")' 2>/dev/null || echo "")
  # Ephemeral/scratch session (cwd under the system temp dir, e.g. Comet's
  # dictation-cleanup CLI)? Blank the id so the block below skips it — those
  # aren't real missions and must not flip a phantom row to "Paused".
  case "$S_CWD" in /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*) S_SID="" ;; esac
  if [ -n "$S_SID" ]; then
    # Session Signature: a ~48-char single-line snippet of the LAST assistant
    # message — the highest-signal per-row discriminator ("what this session just
    # did"), updated every turn (unlike the sticky first-message name). Parsed
    # from the same transcript tail the canon picker reads at step 5; done here so
    # it rides the phase:"waiting" POST rather than adding a request. Best-effort
    # and fully guarded — no transcript / no assistant text simply omits it.
    S_TRANSCRIPT=$(printf '%s' "$EVENT_JSON" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("transcript_path",""))
except: print("")' 2>/dev/null || echo "")
    S_ACTION=""
    if [ -n "$S_TRANSCRIPT" ] && [ -f "$S_TRANSCRIPT" ]; then
      S_ACTION=$(tail -c 200000 "$S_TRANSCRIPT" 2>/dev/null | python3 -c '
import sys, json, re
last = ""
for raw in sys.stdin:
    raw = raw.strip()
    if not raw or not raw.startswith("{"): continue
    try: ev = json.loads(raw)
    except: continue
    if ev.get("type") != "assistant": continue
    for chunk in ev.get("message", {}).get("content", []):
        if chunk.get("type") == "text" and chunk.get("text"):
            last = chunk["text"]
# First non-empty line, whitespace-collapsed, capped at 48 chars.
line = ""
for l in last.splitlines():
    l = " ".join(l.split())
    if l:
        line = l
        break
print(line[:48])
' 2>/dev/null || echo "")
    fi
    S_BODY=$(python3 -c 'import sys,json
sid,cwd,action=sys.argv[1],sys.argv[2],sys.argv[3]
d={"session_id":sid,"phase":"waiting"}
if cwd: d["cwd"]=cwd
if action: d["last_action"]=action
print(json.dumps(d))' "$S_SID" "$S_CWD" "$S_ACTION" 2>/dev/null || echo "")
    if [ -n "$S_BODY" ]; then
      ( curl -sf --max-time 2 -X POST -H 'Content-Type: application/json' \
          -d "$S_BODY" "$DAEMON/session/activity" >/dev/null 2>&1 || true ) &
    fi
  fi
fi

# 2. Pull /settings once — check muted state
SETTINGS=$(curl -sf --connect-timeout 1 "$DAEMON/settings" 2>/dev/null || echo "{}")
MUTED=$(echo "$SETTINGS" | python3 -c 'import sys,json
try: print("true" if json.load(sys.stdin).get("muted") else "false")
except: print("false")' 2>/dev/null || echo "false")

# Muted? Full silent mode — no playback, no fallback line.
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
#    Fallback floor only — if no cached canon matches this context, daemon
#    returns 204 and we stay silent rather than fire an irrelevant guess.
"$SAY" --canon "$CONTEXT" >/dev/null 2>&1 || true

exit 0
