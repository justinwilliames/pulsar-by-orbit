#!/usr/bin/env bash
# pretooluse.sh — Pulsar plumbing. Fires on EVERY tool call mid-turn
# (PreToolUse hook) = a real-time "this session is working NOW" heartbeat.
#
# The problem it fixes: a MAIN session sets phase="working" once at turn-start
# and only clears it at Stop. So a session that's idle-but-unstopped (waiting on
# a slow model, or just paused between tools) still reads "Working" on the board
# — a stale, untrustworthy pill. This hook adds the missing LIVE layer: while a
# session is actively firing tools, it pings the daemon; when it goes quiet, the
# pings stop and the daemon's 30s freshness window lets it fall back to rest.
#
# This is a PURE HEARTBEAT — it carries NO user_message, NO phase, NO name. It
# only says "active right now, doing <X>, as <category>". The daemon stamps
# lastActiveAt and the board pulses the parent + shows the action line.
#
# Wired in by install-hooks.sh as a PreToolUse hook.

# Recursion guard. The LLM-title step in turn-start.sh invokes `claude` again
# under PULSAR_NAMING=1; that nested run must NOT re-fire this hook (it would
# spam heartbeats for a naming sub-run). Every Pulsar hook honours this flag.
[ -n "$PULSAR_NAMING" ] && exit 0

input=$(cat 2>/dev/null)

sid=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id // ""' 2>/dev/null)
[ -z "$sid" ] && exit 0

cwd=$(printf '%s' "$input" | /usr/bin/jq -r '.cwd // ""' 2>/dev/null)

# Skip ephemeral / scratch sessions — same guard as turn-start.sh. A cwd under
# the system temp dir is never real project work (throwaway `claude` runs, e.g.
# dictation cleanup) and shouldn't pulse the board.
case "$cwd" in
  /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*) exit 0 ;;
esac

tool=$(printf '%s' "$input" | /usr/bin/jq -r '.tool_name // ""' 2>/dev/null)
[ -z "$tool" ] && exit 0

# Task (sub-agent spawn) is owned entirely by subagent-start.sh / subagent-stop.sh
# — they register the drone's own presence. A heartbeat here would double-count.
[ "$tool" = "Task" ] && exit 0

# Categorise the tool into an ACTIVE drone category (mirrors subagent-start.sh's
# taxonomy): read-ish tools → voyager (explorer), write/exec → nova (builder),
# anything else → pulsar (the generic orchestrator).
case "$tool" in
  Read|Grep|Glob|LS|WebFetch|WebSearch|NotebookRead) category="voyager" ;;
  Edit|Write|MultiEdit|NotebookEdit)                 category="nova" ;;
  Bash)                                              category="nova" ;;
  *)                                                 category="pulsar" ;;
esac

# Build a short (≤40 char) human-readable action from tool_name + a key field of
# tool_input. python3 parses the object safely (tool_input is arbitrary JSON) and
# derives the basename of file_path / the command prefix without extra shell-outs.
current_action=$(printf '%s' "$input" | TOOL_NAME="$tool" /usr/bin/python3 -c '
import sys, json, os

tool = os.environ.get("TOOL_NAME", "")
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
ti = d.get("tool_input")
if not isinstance(ti, dict):
    ti = {}

def base(p):
    p = str(p or "").strip()
    return os.path.basename(p.rstrip("/")) if p else ""

if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    b = base(ti.get("file_path") or ti.get("notebook_path"))
    action = ("Editing " + b) if b else "Editing"
elif tool in ("Read", "NotebookRead"):
    b = base(ti.get("file_path") or ti.get("notebook_path"))
    action = ("Reading " + b) if b else "Reading"
elif tool in ("Grep", "Glob"):
    action = "Searching"
elif tool == "Bash":
    # SECURITY (2026-07-06 review, R4 item 5): NEVER ship raw command text —
    # shell fragments can carry paths/tokens/args and this string crosses the
    # local HTTP boundary and renders on the board. The tool_input.description
    # field is the model-authored, display-safe verb phrase; fall back to a
    # generic verb when absent.
    desc = " ".join(str(ti.get("description", "")).split())
    action = desc if desc else "Running a command"
elif tool in ("WebFetch", "WebSearch"):
    action = "Searching the web"
else:
    action = tool

print(action[:40])
' 2>/dev/null)
[ -z "$current_action" ] && current_action="$tool"

# Pure heartbeat POST — backgrounded, silent, non-fatal, short timeout so it can
# never delay the tool call. NO user_message / phase / name: this only stamps the
# live-activity fields (active_now, current_action, active_category).
body=$(/usr/bin/jq -n \
  --arg sid "$sid" \
  --arg action "$current_action" \
  --arg cat "$category" \
  '{session_id: $sid, active_now: true, current_action: $action, active_category: $cat}' 2>/dev/null)

if [ -n "$body" ]; then
  ( curl -sf --max-time 2 -X POST -H 'Content-Type: application/json' \
      -d "$body" http://127.0.0.1:7865/session/activity >/dev/null 2>&1 || true ) &
fi

exit 0
