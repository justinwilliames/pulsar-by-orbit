#!/usr/bin/env bash
# subagent-stop.sh — Pulsar plumbing. Fires when a Claude Code sub-agent
# finishes (SubagentStop hook). Tells the app to fade the corresponding drone
# out by POSTing {agent_id} to /subagent/stop.
#
# It does NOT speak a canned "<Name>, done." line — agents report their own
# completion bespoke. This hook only clears drone PRESENCE.
#
# Claude Code passes hook JSON on STDIN. We parse with python3 (no jq).
# Best-effort + silent: if the app is down or anything fails, exit 0.

set -euo pipefail

SPEAK_PORT="${SPEAK_PORT:-7865}"
DAEMON="http://127.0.0.1:$SPEAK_PORT"

input=$(cat 2>/dev/null || true)

BODY=$(printf '%s' "$input" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

agent_id = str(d.get("agent_id") or d.get("agentId") or d.get("session_id") or "").strip()
print(json.dumps({"agent_id": agent_id}))
' 2>/dev/null || true)

[ -z "$BODY" ] && exit 0

AGENT_ID=$(printf '%s' "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("agent_id",""))' 2>/dev/null || true)
[ -z "$AGENT_ID" ] && exit 0

# Clear the drone (orbit/swarm presence). NO say.sh call — the agent reports
# its own completion.
curl -sf --max-time 2 -X POST -H "Content-Type: application/json" \
  -d "$BODY" "$DAEMON/subagent/stop" >/dev/null 2>&1 || true
exit 0
