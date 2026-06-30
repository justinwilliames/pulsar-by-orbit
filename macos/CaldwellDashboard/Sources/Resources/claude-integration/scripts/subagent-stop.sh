#!/usr/bin/env bash
# subagent-stop.sh — Pulsar plumbing. Fires when a Claude Code sub-agent
# finishes (SubagentStop hook). Tells the app to fade the corresponding drone
# out by POSTing {agent_id} to /subagent/stop, then fires a brief in-character
# VOCAL COMPLETION line so the drone reappears to CONFIRM it's done.
#
# The stop payload has agent_id + agent_type, so the category is re-derived from
# agent_type the same way subagent-start.sh does (keep the maps in sync). We
# parse with python3 (no jq). NO LLM calls.
# Best-effort + silent: if the app is down or anything fails, exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAY="$SCRIPT_DIR/say.sh"

SPEAK_PORT="${SPEAK_PORT:-7865}"
DAEMON="http://127.0.0.1:$SPEAK_PORT"

input=$(cat 2>/dev/null || true)

# Resolve {agent_id, category, line}. Category re-derived from agent_type (+ a
# prompt keyword fallback), mirroring subagent-start.sh. `line` is the brief
# completion confirmation, "<Name>, done."
PARSED=$(printf '%s' "$input" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

agent_id = str(d.get("agent_id") or d.get("agentId") or d.get("session_id") or "").strip()
agent_type = str(d.get("agent_type") or d.get("agentType") or d.get("subagent_type") or "").strip().lower()
prompt = ""
for k in ("description", "prompt", "task", "message"):
    v = d.get(k)
    if isinstance(v, str) and v:
        prompt += " " + v
prompt = prompt.lower()

# Keep these maps identical to subagent-start.sh.
TYPE_MAP = {
    "explore": "voyager", "explorer": "voyager",
    "review": "sentinel", "reviewer": "sentinel", "security-review": "sentinel",
    "build": "nova", "builder": "nova", "general-purpose": "atlas",
    "artist": "nebula", "design": "nebula", "designer": "nebula",
    "write": "echo", "writer": "echo", "scribe": "echo",
    "general": "atlas", "generalist": "atlas",
}
KEYWORDS = [
    (("explore", "search", "find", "investigat", "locate", "research"), "voyager"),
    (("review", "audit", "critique", "security", "vulnerab", "lint"), "sentinel"),
    (("build", "implement", "refactor", "compile", "code", "fix"), "nova"),
    (("design", "art", "image", "icon", "visual", "illustrat", "logo"), "nebula"),
    (("write", "draft", "copy", "doc", "changelog", "prose", "blog"), "echo"),
]

category = TYPE_MAP.get(agent_type, "")
if not category:
    for words, cat in KEYWORDS:
        if any(w in agent_type for w in words) or any(w in prompt for w in words):
            category = cat
            break
if not category:
    category = "atlas"

line = category.capitalize() + ", done."
print(json.dumps({"agent_id": agent_id, "category": category, "line": line}))
' 2>/dev/null || true)

[ -z "$PARSED" ] && exit 0

read_field() { printf '%s' "$PARSED" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || true; }
AGENT_ID="$(read_field agent_id)"
CATEGORY="$(read_field category)"
LINE="$(read_field line)"

[ -z "$AGENT_ID" ] && exit 0

# Fade the drone out (orbit/swarm state) — body is {agent_id}.
STOP_BODY=$(printf '%s' "$PARSED" | python3 -c 'import json,sys; print(json.dumps({"agent_id": json.load(sys.stdin).get("agent_id","")}))' 2>/dev/null || true)
curl -sf --max-time 2 -X POST -H "Content-Type: application/json" \
  -d "$STOP_BODY" "$DAEMON/subagent/stop" >/dev/null 2>&1 || true

# Speak the completion so the drone reappears to confirm it's done. The
# acceptance/completion lines queue + hand off directly (no Pulsar beat between).
if [ -n "$LINE" ] && [ -n "$CATEGORY" ] && [ -x "$SAY" ]; then
  "$SAY" --agent "$CATEGORY" "$LINE" >/dev/null 2>&1 || true
fi
exit 0
