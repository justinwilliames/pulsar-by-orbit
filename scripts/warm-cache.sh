#!/usr/bin/env bash
# warm-cache.sh — Pre-cache the canonical Tier 0 phrases at first install.
#
# Why: every turn-end ping picks from a small canon of neutral status phrases.
# The first time each phrase fires it synthesises via native voice (free).
# Pre-warming ensures smooth playback from day one — no slow-start period.
#
# Hits the daemon's /speak endpoint with cache_only=true, which synthesises +
# caches the audio without enqueueing for playback. So the install is silent.

set -e

DAEMON="${DAEMON:-http://127.0.0.1:7865}"

# Canonical Tier 0 phrases. SOURCE OF TRUTH is the `canonContexts` dict in
# macos/CaldwellDashboard/Sources/HTTPServer/CaldwellHTTPServer.swift — this
# array must be the full union of every phrase there (byte-for-byte), or the
# picker will choose a line that was never cached and silently fall through.
# Adding a context phrase in Swift? Add it here too, then re-run this script.

ALL_PHRASES=(
  # push
  "Pushed."
  "Push complete."
  "Changes pushed."
  "Sent up."
  "Push done."
  # tests-pass
  "Tests passing."
  "Tests green."
  "All tests passed."
  "Suite passing."
  "Green."
  # build-pass
  "Build complete."
  "Build succeeded."
  "Build green."
  "Compiled clean."
  "Clean build."
  # found
  "Found it."
  "Located."
  "Got it."
  "There it is."
  "Identified."
  # fail
  "That failed."
  "Something errored."
  "Check the output."
  "Failed."
  "Error — check logs."
  # done
  "Done."
  "Task complete."
  "Finished."
  "Ready."
  "Complete."
  # start
  "On it."
  "Starting."
  "Looking into it."
  "In progress."
  # ack
  "Noted."
  "Got it."
  "Understood."
  "Confirmed."
  "Acknowledged."
  # reassure
  "All clear."
  "No issues."
  "Looking good."
  "Nothing to worry about."
  # neutral
  "Ready."
  "Complete."
  "Finished."
  "Task complete."
)

TOTAL=${#ALL_PHRASES[@]}

# Daemon up?
if ! curl -sf --connect-timeout 2 "$DAEMON/health" >/dev/null 2>&1; then
  echo "Error: daemon not reachable at $DAEMON" >&2
  echo "Start the Pulsar app ('open -a Pulsar') or check the LaunchAgent, then re-run." >&2
  exit 1
fi

echo "Warming canonical phrase cache — $TOTAL phrases (native voice, no API cost)…"
echo

WARMED=0
ALREADY=0
FAILED=0
INDEX=0

for phrase in "${ALL_PHRASES[@]}"; do
  INDEX=$((INDEX + 1))
  BODY=$(python3 -c "import json, sys; print(json.dumps({'text': sys.argv[1], 'cache_only': True}))" "$phrase")
  RESPONSE=$(curl -sf -X POST -H "Content-Type: application/json" -d "$BODY" "$DAEMON/speak" 2>/dev/null || echo '{"error":"network"}')
  STATUS=$(echo "$RESPONSE" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get("cached"):
        print("fresh" if d.get("fresh") else "already")
    else:
        err = d.get("error", "unknown")
        print(("failed:" + str(err))[:60])
except Exception:
    print("failed:parse")' 2>/dev/null || echo "failed:parse")

  case "$STATUS" in
    fresh)
      printf "  [%2d/%d] %-50s ✓ cached\n" "$INDEX" "$TOTAL" "\"$phrase\""
      WARMED=$((WARMED + 1))
      # Brief pause between syntheses to avoid saturating the audio queue.
      sleep 1
      ;;
    already)
      printf "  [%2d/%d] %-50s · already cached\n" "$INDEX" "$TOTAL" "\"$phrase\""
      ALREADY=$((ALREADY + 1))
      ;;
    *)
      printf "  [%2d/%d] %-50s ✗ %s\n" "$INDEX" "$TOTAL" "\"$phrase\"" "$STATUS"
      FAILED=$((FAILED + 1))
      ;;
  esac
done

echo
echo "Done — $WARMED freshly cached, $ALREADY already cached, $FAILED failed."
if [ "$FAILED" -gt 0 ]; then
  echo "Re-run the script later to retry failures (idempotent: cached phrases are skipped)."
  exit 1
fi
exit 0
