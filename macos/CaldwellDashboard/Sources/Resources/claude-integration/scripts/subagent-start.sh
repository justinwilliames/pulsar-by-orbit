#!/usr/bin/env bash
# subagent-start.sh — Pulsar plumbing. Fires when Claude Code spawns a
# sub-agent (SubagentStart hook). Categorises the sub-agent into one of
# Pulsar's drone types, tells the app to show it as an in-flight drone, AND
# fires a short in-character VOCAL ACCEPTANCE line so the drone appears WITH
# its voice rather than hovering silently.
#
# Claude Code passes hook JSON on STDIN (fields include agent_id and
# agent_type, and sometimes a prompt). We parse with python3 (no jq) and POST
# {agent_id, category} to /subagent/start, then speak the acceptance via
# say.sh --agent <category>. NO LLM calls — a static agent_type map, then a
# keyword match on the prompt, then a fallback of "atlas"; the line is a
# template + an optional task hint from the payload.
# Best-effort + silent: if the app is down or anything fails, exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAY="$SCRIPT_DIR/say.sh"

SPEAK_PORT="${SPEAK_PORT:-7865}"
DAEMON="http://127.0.0.1:$SPEAK_PORT"

input=$(cat 2>/dev/null || true)

# Resolve {agent_id, category, line} from the hook payload. The category map is
# the locked drone taxonomy: explorer→voyager, reviewer→sentinel, builder→nova,
# artist→nebula, writer→echo, generalist→atlas. Unknown agent_types fall back
# to a keyword match on the prompt, then to "atlas". `line` is a short in-
# character acceptance, built from a task hint if present else a per-role generic.
PARSED=$(printf '%s' "$input" | python3 -c '
import json, sys, re

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

agent_id = str(d.get("agent_id") or d.get("agentId") or d.get("session_id") or "").strip()
agent_type = str(d.get("agent_type") or d.get("agentType") or d.get("subagent_type") or "").strip().lower()

hint_raw = ""
for k in ("description", "prompt", "task", "message"):
    v = d.get(k)
    if isinstance(v, str) and v.strip():
        hint_raw = v.strip()
        break
prompt = hint_raw.lower()

# Static agent_type -> drone map. Keys cover the named agent types plus their
# canonical roles, so "Explore"/"explorer", "review"/"reviewer", etc. all land.
TYPE_MAP = {
    "explore": "voyager", "explorer": "voyager",
    "review": "sentinel", "reviewer": "sentinel", "security-review": "sentinel",
    "build": "nova", "builder": "nova", "general-purpose": "atlas",
    "artist": "nebula", "design": "nebula", "designer": "nebula",
    "write": "echo", "writer": "echo", "scribe": "echo",
    "general": "atlas", "generalist": "atlas",
}

# Keyword fallback when agent_type is absent/unknown. Ordered: first hit wins.
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

NAME = category.capitalize()

# Per-role generic acceptance when there is no usable task hint.
GENERIC = {
    "voyager":  NAME + " here, scouting ahead.",
    "sentinel": NAME + " here, reviewing the work.",
    "nova":     NAME + " here, building it.",
    "nebula":   NAME + " here, making it beautiful.",
    "echo":     NAME + " here, writing it up.",
    "atlas":    NAME + " here, on the job.",
}

# Build the line: "<Name> here. <short hint>." truncated to ~8 hint words, else
# the per-role generic. Strip newlines/extra whitespace from the hint.
line = ""
hint = re.sub(r"\s+", " ", hint_raw).strip()
if hint:
    words = hint.split(" ")[:8]
    short = " ".join(words).strip().rstrip(".,;:!?")
    if short:
        line = NAME + " here. " + short + "."
if not line:
    line = GENERIC.get(category, NAME + " here, on the job.")

print(json.dumps({"agent_id": agent_id, "category": category, "line": line}))
' 2>/dev/null || true)

[ -z "$PARSED" ] && exit 0

# Pull the resolved fields back out.
read_field() { printf '%s' "$PARSED" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || true; }
AGENT_ID="$(read_field agent_id)"
CATEGORY="$(read_field category)"
LINE="$(read_field line)"

# Bail quietly if we couldn't resolve an agent_id.
[ -z "$AGENT_ID" ] && exit 0

# Register the drone (orbit/swarm state) — body is {agent_id, category}.
START_BODY=$(printf '%s' "$PARSED" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"agent_id": d.get("agent_id",""), "category": d.get("category","atlas")}))' 2>/dev/null || true)
curl -sf --max-time 2 -X POST -H "Content-Type: application/json" \
  -d "$START_BODY" "$DAEMON/subagent/start" >/dev/null 2>&1 || true

# Speak the acceptance so the drone appears WITH its voice. The speak path tags
# the line with the drone category, so the app swaps that drone into the centre.
if [ -n "$LINE" ] && [ -n "$CATEGORY" ] && [ -x "$SAY" ]; then
  "$SAY" --agent "$CATEGORY" "$LINE" >/dev/null 2>&1 || true
fi
exit 0
