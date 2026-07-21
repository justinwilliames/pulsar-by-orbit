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
# HOW THE CATEGORY IS RESOLVED (verified live 2026-07-21):
# The hook payload carries NO task text — only {session_id, transcript_path,
# cwd, prompt_id, agent_id, agent_type, hook_event_name}. But Claude Code
# writes per-agent files under the parent session dir:
#   <transcript_path minus .jsonl>/subagents/agent-<id>.meta.json  (description;
#     lands ~1s after the hook fires)
#   <transcript_path minus .jsonl>/subagents/agent-<id>.jsonl      (full prompt
#     as the first user entry; can lag the hook by many seconds)
# So: register FAST with the best category knowable now (agent_type map +
# whatever text is already on disk), then — if that resolved generic — hand off
# to a DETACHED background upgrader (--upgrade mode, below) that polls the
# files for a few seconds and re-registers when the real text lands. The daemon
# upgrades a generic (atlas/unknown) category on re-register and never demotes
# a specific one, so the upgrade path is idempotent and safe.
# Best-effort + silent: if the app is down or anything fails, exit 0.

set -euo pipefail

SPEAK_PORT="${SPEAK_PORT:-7865}"
DAEMON="http://127.0.0.1:$SPEAK_PORT"

# Categorise a payload (JSON passed as $1) → {agent_id, category[, session_id]}.
# UP_AGENT_ID / UP_SESSION_ID / UP_TP env vars override the payload fields —
# that is how --upgrade mode reuses this single categorisation path.
categorise() {
  printf '%s' "$1" | AGENT_ID_FALLBACK="$(uuidgen 2>/dev/null || true)" python3 -c '
import json, os, re, sys, time

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

# agent_id: prefer the real per-agent id. NEVER fall back to session_id — two
# sibling sub-agents share one session_id, so that fallback would collapse them
# onto a single drone (one Stop then clears BOTH). A generated uuid keeps every
# agent distinct even in the (unobserved) case where agent_id is missing.
agent_id = str(os.environ.get("UP_AGENT_ID") or d.get("agent_id") or d.get("agentId") or os.environ.get("AGENT_ID_FALLBACK") or "").strip()
# session_id is captured SEPARATELY (not as an agent_id fallback) so the daemon
# can session-scope claim-on-speak promotion.
session_id = str(os.environ.get("UP_SESSION_ID") or d.get("session_id") or d.get("sessionId") or "").strip()
agent_type = str(d.get("agent_type") or d.get("agentType") or d.get("subagent_type") or "general-purpose").strip().lower()

# Recover the per-agent task text from the meta + transcript files (see header).
# Inline attempts are FAST (files usually lag the hook); the background
# --upgrade pass carries the real wait.
task_text = ""
tp = str(os.environ.get("UP_TP") or d.get("transcript_path") or "")
if agent_id and tp.endswith(".jsonl"):
    base = tp[:-6]
    meta_p = os.path.join(base, "subagents", "agent-" + agent_id + ".meta.json")
    jl_p = os.path.join(base, "subagents", "agent-" + agent_id + ".jsonl")
    for _attempt in range(2):
        got = False
        try:
            with open(meta_p) as f:
                m = json.load(f)
            task_text += " " + str(m.get("description") or "")
            if not agent_type:
                agent_type = str(m.get("agentType") or "").strip().lower()
            got = True
        except Exception:
            pass
        try:
            with open(jl_p) as f:
                e = json.loads(f.readline())
            c = e.get("message", {}).get("content", "")
            if isinstance(c, list):
                c = " ".join(str(x.get("text", "")) if isinstance(x, dict) else str(x) for x in c)
            task_text += " " + str(c)[:4000]
            got = True
        except Exception:
            pass
        if got:
            break
        time.sleep(0.15)

# Legacy payload text fields (absent today; kept in case the platform adds them).
for k in ("description", "prompt", "task", "message"):
    v = d.get(k)
    if isinstance(v, str) and v:
        task_text += " " + v
prompt = task_text.lower()

CAST = "voyager|sentinel|nova|nebula|echo|iris|atlas"

# Static agent_type -> drone map. Keys cover the named agent types plus their
# canonical roles, so "Explore"/"explorer", "review"/"reviewer", etc. all land.
TYPE_MAP = {
    "explore": "voyager", "explorer": "voyager",
    "review": "sentinel", "reviewer": "sentinel", "security-review": "sentinel",
    "build": "nova", "builder": "nova", "general-purpose": "atlas",
    "artist": "nebula", "design": "nebula", "designer": "nebula",
    "write": "nebula", "writer": "nebula", "scribe": "nebula",
    "marketer": "iris", "marketing": "iris",
    "general": "atlas", "generalist": "atlas",
    "claude": "atlas", "plan": "atlas", "task": "atlas",
}

# Keyword fallback. Ordered: first hit wins.
# NOTE: this whole python block sits inside shell single-quotes — NO
# apostrophes in comments or strings here, or the script fails to parse.
# The iris tuple runs FIRST: its terms are unambiguous marketing signals, and
# several would otherwise be swallowed upstream ("paid search" hits the
# voyager "search" keyword; "deliverability review" hits the sentinel
# "review"). Drafting/copy terms stay with nebula (nebula owns creative
# EXECUTION; iris owns marketing strategy, channels, and measurement).
KEYWORDS = [
    (("lifecycle", "braze", "deliverab", "paid media", "paid search", "seo",
      "sem ", "marketing", "retention", "winback", "win-back", "activation",
      "segment", "utm", "cac", "ltv", "attribution", "crm", "hubspot"), "iris"),
    (("explore", "search", "find", "investigat", "locate", "research"), "voyager"),
    (("review", "audit", "critique", "security", "vulnerab", "lint"), "sentinel"),
    (("build", "implement", "refactor", "compile", "code", "fix"), "nova"),
    (("design", "art", "image", "icon", "visual", "illustrat", "logo"), "nebula"),
    (("write", "draft", "copy", "doc", "changelog", "prose", "blog", "content"), "nebula"),
]

GENERALIST_TYPES = {"general-purpose", "general", "generalist", "claude", "plan", "task", ""}

# Priority 1 — the EXPLICIT cast marker in the brief. subagent-brief spawns
# open with "You are <Drone>, the <category> drone ..." and include a say.sh
# line with "--agent <category>". Authorial intent beats every heuristic.
category = ""
m = (re.search(r"\byou are (" + CAST + r")\b", prompt)
     or re.search(r"--agent (" + CAST + r")\b", prompt)
     or re.search(r"\b(" + CAST + r") drone\b", prompt))
if m:
    category = m.group(1)

# Priority 2 — unique bare drone name anywhere in the text ("Voyager race
# re-probe" in a Task description names the character without any marker
# phrase). Only when EXACTLY ONE cast name appears — a brief that mentions
# several drones (an orchestration task) is ambiguous, so skip.
if not category:
    names = set(re.findall(r"\b(" + CAST + r")\b", prompt))
    if len(names) == 1:
        category = names.pop()

# Priority 3 — specific agent_type map (Explore -> voyager etc.).
if not category and agent_type not in GENERALIST_TYPES:
    category = TYPE_MAP.get(agent_type, "")

# Priority 4 — keyword match over the recovered task text.
if not category:
    for words, cat in KEYWORDS:
        if any(w in agent_type for w in words) or any(w in prompt for w in words):
            category = cat
            break

# Priority 5 — generalist home / neutral unknown.
if not category:
    category = "atlas" if agent_type in GENERALIST_TYPES else "unknown"

out = {"agent_id": agent_id, "category": category}
if session_id:
    out["session_id"] = session_id
print(json.dumps(out))
' 2>/dev/null || true
}

post_registration() {
  curl -sf --max-time 2 -X POST -H "Content-Type: application/json" \
    -d "$1" "$DAEMON/subagent/start" >/dev/null 2>&1 || true
}

extract() { # $1 = json, $2 = field
  printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true
}

# ── Background upgrade mode ─────────────────────────────────────────────────
# $0 --upgrade <agent_id> <session_id> <transcript_path>
# Polls the per-agent files until the task text yields a SPECIFIC category,
# then re-registers (the daemon upgrades generic labels in place). Gives up
# quietly after ~8s — claim-on-speak remains the final fallback.
if [ "${1:-}" = "--upgrade" ]; then
  UA="${2:-}"; US="${3:-}"; UT="${4:-}"
  if [ -z "$UA" ] || [ -z "$UT" ]; then exit 0; fi
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.8
    P=$(UP_AGENT_ID="$UA" UP_SESSION_ID="$US" UP_TP="$UT" categorise '{}')
    C=$(extract "$P" category)
    if [ -n "$C" ] && [ "$C" != "atlas" ] && [ "$C" != "unknown" ]; then
      post_registration "$P"
      exit 0
    fi
  done
  exit 0
fi

# ── Normal hook mode ────────────────────────────────────────────────────────
input=$(cat 2>/dev/null || true)

# Diagnostic: keep the LAST raw hook payload on disk (single file, overwritten
# each spawn) so payload-shape questions get answered by observation.
printf '%s' "$input" > "$HOME/.claude/pulsar-last-subagent-payload.json" 2>/dev/null || true

PARSED=$(categorise "$input")
[ -z "$PARSED" ] && exit 0

AGENT_ID=$(extract "$PARSED" agent_id)
[ -z "$AGENT_ID" ] && exit 0

# Register the drone (orbit/swarm presence). NO say.sh call — the agent speaks
# for itself.
post_registration "$PARSED"

# If the fast pass resolved only a generic label, hand off to the detached
# upgrader — the per-agent task text usually lands within a second or two.
CATEGORY=$(extract "$PARSED" category)
if [ "$CATEGORY" = "atlas" ] || [ "$CATEGORY" = "unknown" ]; then
  SESSION_ID=$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("session_id") or d.get("sessionId") or "")' 2>/dev/null || true)
  TP=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("transcript_path",""))' 2>/dev/null || true)
  if [ -n "$TP" ]; then
    ( nohup "$0" --upgrade "$AGENT_ID" "$SESSION_ID" "$TP" >/dev/null 2>&1 & ) 2>/dev/null || true
  fi
fi
exit 0
