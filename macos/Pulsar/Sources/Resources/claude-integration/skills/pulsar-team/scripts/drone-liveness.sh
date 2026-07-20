#!/usr/bin/env bash
# drone-liveness.sh — mechanical stall detector for spawned drones/sub-agents.
#
# A backgrounded agent can HANG without ever emitting a completion event, so
# "no notification" != "still working". This distinguishes live / done / stalled
# from two observable signals: (1) transcript-file mtime staleness (a live agent's
# transcript keeps growing; a hung one goes flat) and (2) expected-output-file
# existence (the real completion proof — the drone's R1-<name>.md, not a notice).
#
# Usage:
#   drone-liveness.sh <tasks_dir> <stall_seconds> <manifest_file>
#   manifest lines:  <agentId>|<label>|<expected_output_path>
#     - expected_output_path may be empty (then completion = agent stopped, not file)
#
# Exit code: 0 if none stalled, 2 if one or more STALLED (so a caller can gate on it).
#
# Poll this on a loop (~every 180s) after each parallel wave until every agent is
# done-or-stalled, with a hard cutoff (pulsar-team default: 10 min stall -> escalate).
set -uo pipefail

TASKS_DIR="${1:?tasks_dir required (dir holding <agentId>.output transcripts)}"
STALL="${2:?stall_seconds required (e.g. 180)}"
MANIFEST="${3:?manifest_file required}"
NOW=$(date +%s)
stalled=0

printf "%-20s %-8s %-10s %s\n" "DRONE" "OUTPUT" "IDLE" "STATUS"
printf "%-20s %-8s %-10s %s\n" "-----" "------" "----" "------"

while IFS='|' read -r id label out; do
  [ -z "${id:-}" ] && continue
  [[ "$id" =~ ^# ]] && continue
  tp="$TASKS_DIR/$id.output"
  # transcript idle time
  if [ -f "$tp" ]; then idle=$(( NOW - $(stat -f %m "$tp" 2>/dev/null || stat -c %Y "$tp") )); else idle=-1; fi
  # output-file completion proof (>200B = real content, not a stub)
  osize=0; [ -n "${out:-}" ] && [ -f "$out" ] && osize=$(wc -c < "$out" | tr -d ' ')
  if [ -n "${out:-}" ] && [ "$osize" -gt 200 ]; then
    ostate="yes"; status="✅ done"
  elif [ "$idle" -lt 0 ]; then
    ostate="-"; status="⏳ no-transcript-yet"
  elif [ "$idle" -gt "$STALL" ]; then
    ostate="no"; status="🔴 STALLED (${idle}s idle, no output)"; stalled=$((stalled+1))
  else
    ostate="no"; status="🟢 live"
  fi
  printf "%-20s %-8s %-10s %s\n" "${label:-$id}" "$ostate" "${idle}s" "$status"
done < "$MANIFEST"

echo ""
if [ "$stalled" -gt 0 ]; then echo "⚠️  $stalled drone(s) STALLED — escalate/re-spawn, do not report as running."; exit 2; fi
echo "no stalls."
exit 0
