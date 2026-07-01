#!/usr/bin/env bash
# subagent-stop.sh — Pulsar plumbing. Fires when a Claude Code sub-agent
# finishes (SubagentStop hook). Tells the app to fade the corresponding drone
# out by POSTing {agent_id} to /subagent/stop.
#
# It does NOT speak a canned "<Name>, done." line — agents report their own
# completion bespoke. This hook only clears drone PRESENCE.
#
# Claude Code passes hook JSON on STDIN. We parse with python3 (no jq).
# Best-effort: NEVER blocks Claude Code (always exits 0), but the stop POST is
# retried up to 3 times, and a total failure is logged (not silently dropped) —
# a swallowed stop is the root of "ghost drones" that never fade out.

set -euo pipefail

SPEAK_PORT="${SPEAK_PORT:-7865}"
DAEMON="http://127.0.0.1:$SPEAK_PORT"
FAIL_LOG="${PULSAR_HOOK_LOG:-$HOME/.claude/pulsar-hook-failures.log}"

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
# its own completion. Retry up to 3 times with a short back-off so a momentary
# hiccup under load doesn't leave a ghost drone stuck in orbit. Best-effort:
# on total failure we LOG (never block Claude Code, but no longer silent).
ok=0
for attempt in 1 2 3; do
  if curl -sf --max-time 4 -X POST -H "Content-Type: application/json" \
       -d "$BODY" "$DAEMON/subagent/stop" >/dev/null 2>&1; then
    ok=1
    break
  fi
  [ "$attempt" -lt 3 ] && sleep 0.3 2>/dev/null || sleep 1 2>/dev/null || true
done

if [ "$ok" -ne 1 ]; then
  { mkdir -p "$(dirname "$FAIL_LOG")" 2>/dev/null || true
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)
    printf '%s subagent-stop FAILED after 3 attempts for %s\n' "$ts" "$BODY" \
      >> "$FAIL_LOG"
  } 2>/dev/null || true
fi
exit 0
