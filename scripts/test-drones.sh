#!/usr/bin/env bash
# test-drones.sh — demo the Pulsar agent swarm without spawning real sub-agents.
# Registers N drones (so the swarm appears), has each speak in turn (each takes
# the centre, then returns to the swarm), shows the idle cluster, then clears them.
#
# Usage:  ./scripts/test-drones.sh [count 1-6]     (default 3)
#   e.g.  ./scripts/test-drones.sh 5
#
# The app must be running (daemon on 127.0.0.1:7865). Nothing here spawns a real
# Claude sub-agent — it just drives the overlay so you can see how the swarm looks.
set -euo pipefail

D="http://127.0.0.1:${SPEAK_PORT:-7865}"
SAY="$(cd "$(dirname "$0")" && pwd)/say.sh"

N="${1:-3}"
case "$N" in ''|*[!0-9]*) N=3 ;; esac
[ "$N" -lt 1 ] && N=1
[ "$N" -gt 6 ] && N=6

if ! curl -sf --max-time 2 "$D/health" >/dev/null 2>&1; then
  echo "Pulsar app isn't running (no daemon on ${D}). Open the app first." >&2
  exit 1
fi

CATS=(voyager sentinel nova nebula echo atlas)
LINES=(
  "Voyager here, scouting the codebase for what we need."
  "Sentinel, reviewing the diff — checking for anything that bites us later."
  "Nova, building it out and getting it compiling."
  "Nebula, making the visuals actually look the part."
  "Echo, writing it up so it reads clean."
  "Atlas, picking up the general odds and ends."
)

ids=()
for i in $(seq 0 $((N - 1))); do
  c="${CATS[$i]}"; id="test-$c"; ids+=("$id")
  curl -sf --max-time 2 -X POST -H 'Content-Type: application/json' \
    -d "{\"agent_id\":\"$id\",\"category\":\"$c\"}" "$D/subagent/start" >/dev/null || true
done

cleanup() {
  for id in "${ids[@]}"; do
    curl -sf --max-time 2 -X POST -H 'Content-Type: application/json' \
      -d "{\"agent_id\":\"$id\"}" "$D/subagent/stop" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

echo "Registered $N drone(s): ${CATS[*]:0:$N}"
"$SAY" "Team assembled — $N on the job. Watch us work, then drop back to the swarm." 2>/dev/null || true
for i in $(seq 0 $((N - 1))); do
  "$SAY" "${LINES[$i]}" --agent "${CATS[$i]}" 2>/dev/null || true
done
echo "Holding the idle swarm for 8s so you can see the cluster…"
sleep 8
echo "Clearing the test agents."
