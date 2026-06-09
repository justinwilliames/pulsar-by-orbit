#!/usr/bin/env bash
# warm-cache.sh — Pre-cache the canonical Tier 0 phrases at first install.
#
# Why: every Caldwell turn-end ping picks from a small canon of generic
# reusable phrases. The first time each phrase fires it costs ElevenLabs
# credits (one-time, ~10-30 chars). Pre-warming on first install means
# every turn from day one is a free cached replay — no slow-start period.
#
# Total one-time cost: ~650 chars of the monthly free-tier 10,000 budget
# (under 7%). All Polite phrases warm always. Potty phrases warm too so
# the cache is ready regardless of which mode Sir picks later.
#
# Hits the daemon's /speak endpoint with cache_only=true, which fetches +
# caches the audio without enqueueing for playback. So the install is
# silent — no 25-line concert during setup.

set -e

DAEMON="${DAEMON:-http://127.0.0.1:7865}"

# Canonical Tier 0 phrases. SOURCE OF TRUTH is the `canonContexts` dict in
# macos/CaldwellDashboard/Sources/HTTPServer/CaldwellHTTPServer.swift — this
# array must be the full union of every phrase there (byte-for-byte), or the
# picker will choose a line that was never cached and silently fall through.
# Adding a context phrase in Swift? Add it here too, then re-run this script.

POLITE_PHRASES=(
  # neutral — generic acknowledgements, safe after any turn
  "Quite, Sir."
  "Very good, Sir."
  "Right then, Sir."
  "Noted, Sir."
  "Right you are, Sir."
  "As you wish, Sir."
  # start
  "Right then Sir."
  "Right then Sir, on it."
  "On it, Sir."
  "Onto it."
  "I'll have a look."
  # done
  "Sorted, Sir."
  "Sorted."
  "Bit of a faff, that."
  "Job's a good 'un, Sir."
  # ack
  "Most kind, Sir."
  # fail
  "Most regrettable, Sir."
  "Cocked it up, Sir."
  # push / tests / build / found
  "Pushed, Sir."
  "Pushed."
  "Tests passing."
  "All green, Sir."
  "Build's clean."
  "Compiled clean, Sir."
  "Found it, Sir."
  "There it is, Sir."
)

POTTY_PHRASES=(
  "Fuckin' pushed."
  "Tests fuckin' passing."
  "Bollocks."
  "Bloody hell, Sir."
  "Sorted, fuckin' done."
  "Bloody well done, that."
  "Right then Sir, fuckin' on it."
  "Sweet fuck-all to worry about, Sir."
  "Bloody good, Sir."
  "Right you fuckin' are, Sir."
)

ALL_PHRASES=("${POLITE_PHRASES[@]}" "${POTTY_PHRASES[@]}")
TOTAL=${#ALL_PHRASES[@]}

# Daemon up?
if ! curl -sf --connect-timeout 2 "$DAEMON/health" >/dev/null 2>&1; then
  echo "Error: daemon not reachable at $DAEMON" >&2
  echo "Start the Caldwell app ('open -a Caldwell') or check the LaunchAgent, then re-run." >&2
  exit 1
fi

# API key present?
API_KEY_SET=$(curl -sf "$DAEMON/settings" | python3 -c 'import sys,json
try: print("true" if json.load(sys.stdin).get("api_key_set") else "false")
except: print("false")')

if [ "$API_KEY_SET" != "true" ]; then
  echo "Error: ElevenLabs API key not set." >&2
  echo "Set it first: ./scripts/say.sh --set-api-key sk_..." >&2
  exit 1
fi

echo "Warming canonical phrase cache — $TOTAL phrases (~475 chars total)…"
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
      # Sleep between fresh fetches to stay under the per-minute rate limit
      # (default 20/min). 4-second pacing keeps us at 15/min, comfortable.
      sleep 4
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
