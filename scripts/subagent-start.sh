#!/usr/bin/env bash
# subagent-start.sh — Pulsar plumbing. Fires when Claude Code spawns a
# sub-agent (SubagentStart hook). Categorises the sub-agent into one of
# Pulsar's drone types and tells the app to show it as an in-flight drone
# orbiting Pulsar.
#
# It does NOT speak a canned acceptance line — agents self-announce their real
# task bespoke (handled by how they're spawned), so a generic "<Name> here…"
# would just double up. This hook only registers drone PRESENCE.
#
# Claude Code passes hook JSON on STDIN (fields include agent_id and
# agent_type, and sometimes a prompt). We parse with python3 (no jq) and POST
# {agent_id, category} to /subagent/start. NO LLM calls — a static agent_type
# map, then a keyword match on the prompt, then a fallback of "unknown"
# (atlas is RESERVED for general-purpose/generalist agents, not a junk drawer).
# Best-effort + silent: if the app is down or anything fails, exit 0.

set -euo pipefail

SPEAK_PORT="${SPEAK_PORT:-7865}"
DAEMON="http://127.0.0.1:$SPEAK_PORT"

input=$(cat 2>/dev/null || true)

# Resolve {agent_id, category} from the hook payload. The category map is the
# locked drone taxonomy: explorer→voyager, reviewer→sentinel, builder→nova,
# creative (writer + artist: drafting, copy, docs, design, image gen)→nebula,
# generalist→atlas. Unknown agent_types fall back
# to a keyword match on the prompt, then to "unknown" (atlas stays reserved for
# genuine generalists — general-purpose/generalist — never a catch-all).
PARSED=$(printf '%s' "$input" | AGENT_ID_FALLBACK="$(uuidgen 2>/dev/null || true)" python3 -c '
import json, os, sys

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

# agent_id: prefer the real per-agent id. NEVER fall back to session_id — two
# sibling sub-agents share one session_id, so that fallback would collapse them
# onto a single drone (one Stop then clears BOTH). A generated uuid keeps every
# agent distinct even in the (unobserved) case where agent_id is missing.
agent_id = str(d.get("agent_id") or d.get("agentId") or os.environ.get("AGENT_ID_FALLBACK") or "").strip()
# session_id is captured SEPARATELY (not as an agent_id fallback) so the daemon
# can session-scope claim-on-speak promotion.
session_id = str(d.get("session_id") or d.get("sessionId") or "").strip()
agent_type = str(d.get("agent_type") or d.get("agentType") or d.get("subagent_type") or "").strip().lower()
prompt = ""
for k in ("description", "prompt", "task", "message"):
    v = d.get(k)
    if isinstance(v, str) and v:
        prompt += " " + v
prompt = prompt.lower()

# Static agent_type -> drone map. Keys cover the named agent types plus their
# canonical roles, so "Explore"/"explorer", "review"/"reviewer", etc. all land.
TYPE_MAP = {
    "explore": "voyager", "explorer": "voyager",
    "review": "sentinel", "reviewer": "sentinel", "security-review": "sentinel",
    "build": "nova", "builder": "nova", "general-purpose": "atlas",
    "artist": "nebula", "design": "nebula", "designer": "nebula",
    "write": "nebula", "writer": "nebula", "scribe": "nebula",
    "general": "atlas", "generalist": "atlas",
}

# Keyword fallback when agent_type is absent/unknown. Ordered: first hit wins.
KEYWORDS = [
    (("explore", "search", "find", "investigat", "locate", "research"), "voyager"),
    (("review", "audit", "critique", "security", "vulnerab", "lint"), "sentinel"),
    (("build", "implement", "refactor", "compile", "code", "fix"), "nova"),
    (("design", "art", "image", "icon", "visual", "illustrat", "logo"), "nebula"),
    (("write", "draft", "copy", "doc", "changelog", "prose", "blog", "content"), "nebula"),
]

category = TYPE_MAP.get(agent_type, "")
if not category:
    for words, cat in KEYWORDS:
        if any(w in agent_type for w in words) or any(w in prompt for w in words):
            category = cat
            break
if not category:
    # Genuinely unrecognised: not in TYPE_MAP and no keyword hit. Emit the
    # distinct "unknown" category (the daemon/registry renders it as a neutral
    # drone). Atlas is NEVER a fallback — it is reserved for general-purpose.
    category = "unknown"

out = {"agent_id": agent_id, "category": category}
if session_id:
    out["session_id"] = session_id
print(json.dumps(out))
' 2>/dev/null || true)

[ -z "$PARSED" ] && exit 0

# Bail quietly if we couldn't resolve an agent_id.
AGENT_ID=$(printf '%s' "$PARSED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("agent_id",""))' 2>/dev/null || true)
[ -z "$AGENT_ID" ] && exit 0

# Register the drone (orbit/swarm presence). NO say.sh call — the agent speaks
# for itself.
curl -sf --max-time 2 -X POST -H "Content-Type: application/json" \
  -d "$PARSED" "$DAEMON/subagent/start" >/dev/null 2>&1 || true
exit 0
