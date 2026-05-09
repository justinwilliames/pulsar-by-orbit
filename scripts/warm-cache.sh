#!/usr/bin/env bash
# warm-cache.sh — Pre-cache the canonical Tier 0 phrases at first install.
#
# Why: every Caldwell turn-end ping picks from a small canon of generic
# reusable phrases. The first time each phrase fires it costs ElevenLabs
# credits (one-time, ~10-30 chars). Pre-warming on first install means
# every turn from day one is a free cached replay — no slow-start period.
#
# Total one-time cost: ~475 chars of the monthly free-tier 10,000 budget
# (under 5%). All Polite phrases warm always. Potty phrases warm too so
# the cache is ready regardless of which mode Sir picks later.
#
# Hits the daemon's /speak endpoint with cache_only=true, which fetches +
# caches the audio without enqueueing for playback. So the install is
# silent — no 25-line concert during setup.

set -e

DAEMON="${DAEMON:-http://127.0.0.1:7865}"

# Canonical Tier 0 phrases — kept in sync with SKILL.md and the hook's
# fallback pool. Changes here should be mirrored to scripts/stop-hook.sh.

POLITE_PHRASES=(
  "Right then Sir."
  "Right then Sir, on it."
  "On it, Sir."
  "Onto it."
  "Quite, Sir."
  "Sorted, Sir."
  "Sorted."
  "Most kind, Sir."
  "Most regrettable, Sir."
  "I'll have a look."
  "Tests passing."
  "Build's clean."
  "Pushed, Sir."
  "Bit of a faff, that."
  "Found it, Sir."
)

POTTY_PHRASES=(
  "Fuckin' pushed."
  "Sorted, fuckin' done."
  "Tests fuckin' passing."
  "Right then Sir, fuckin' on it."
  "Bloody hell, Sir."
  "Bollocks."
  "Cocked it up, Sir."
  "Sweet fuck-all to worry about, Sir."
  "Bloody well done, that."
  "Job's a good 'un, Sir."
)

ALL_PHRASES=("${POLITE_PHRASES[@]}" "${POTTY_PHRASES[@]}")
TOTAL=${#ALL_PHRASES[@]}

# Daemon up?
if ! curl -sf --connect-timeout 2 "$DAEMON/health" >/dev/null 2>&1; then
  echo "Error: daemon not reachable at $DAEMON" >&2
  echo "Start it with 'uv run daemon/server.py' (or check the LaunchAgent) and re-run." >&2
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
        print(f"failed:{d.get(\"error\",\"unknown\")}"[:60])
except: print("failed:parse")' 2>/dev/null || echo "failed:parse")

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
