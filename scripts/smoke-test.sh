#!/usr/bin/env bash
# smoke-test.sh — end-to-end regression guard for the two bugs fixed in v0.6.5:
#
#   1. /history/replay works for EVERY played line (not just phrase-cached
#      canon). Reproduces by speaking a unique, non-cacheable line, waiting for
#      it to land in history, then replaying it by id.
#   2. /usage reflects real character consumption PROMPTLY. ElevenLabs'
#      /v1/user counter lags by tens of seconds; the local counter + max()
#      reconciliation should surface a fresh fetch's characters within seconds.
#
# Requires the Pulsar app running on 127.0.0.1:7865 with a valid API key.
# Speaks two short lines aloud — that's expected for a TTS app's smoke test.
#
# Exit 0 = all pass; non-zero = a regression.

set -uo pipefail

D="${SPEAK_DAEMON:-http://127.0.0.1:7865}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HIST_DIR="${SPEAK_CACHE_DIR:-$REPO_ROOT/cache}/history"
FAILS=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS+1)); }
json() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1',''))" 2>/dev/null; }

if ! curl -sf --max-time 2 "$D/health" >/dev/null 2>&1; then
  echo "Pulsar daemon not reachable at $D — start the app first." >&2
  exit 2
fi

# Wait for the queue to be idle so our line isn't dropped (maxWaitingDepth=1).
for _ in $(seq 1 15); do
  q=$(curl -sf "$D/queue?limit=1")
  [ "$(echo "$q" | json playing)" != "True" ] && [ "$(echo "$q" | json queued)" = "0" ] && break
  sleep 1
done

RID=$RANDOM
TXT="Smoke test line $RID, replay and usage check, one two three four."
LEN=${#TXT}

echo "== Bug 2: usage reflects a fresh fetch promptly =="
U0=$(curl -sf "$D/usage" | json characters_used); U0=${U0:-0}
echo "  baseline characters_used=$U0; speaking $LEN chars (forces a live fetch)"
SPEAK=$(curl -sf -X POST -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,sys;print(json.dumps({'text':sys.argv[1]}))" "$TXT")" "$D/speak")
ID=$(echo "$SPEAK" | json id)
DROPPED=$(echo "$SPEAK" | json dropped)
[ -n "$ID" ] && [ "$DROPPED" != "True" ] && pass "speak accepted (id=$ID)" || { fail "speak dropped/failed: $SPEAK"; }

# Local counter increments when the fetch completes (~1-2s), NOT after the
# ~40s upstream lag. Allow a generous-but-sub-lag window.
PROMPT=0
for t in $(seq 1 8); do
  U=$(curl -sf "$D/usage" | json characters_used); U=${U:-0}
  if [ "$U" -ge "$((U0 + LEN))" ]; then
    pass "usage rose to $U (>= $U0+$LEN) within ${t}s"
    PROMPT=1; break
  fi
  sleep 1
done
[ "$PROMPT" = "1" ] || fail "usage did not reflect +$LEN chars within 8s (still $U) — lag regression"

echo "== Bug 1: replay works for a non-cached history item =="
# History records after playback completes. Poll for our id.
FOUND=0
for _ in $(seq 1 20); do
  if curl -sf "$D/history?limit=50" | python3 -c "import sys,json;ids=[e['id'] for e in json.load(sys.stdin)];sys.exit(0 if '$ID' in ids else 1)"; then
    FOUND=1; break
  fi
  sleep 1
done
[ "$FOUND" = "1" ] && pass "line landed in history" || fail "line never appeared in history"

[ -f "$HIST_DIR/$ID.mp3" ] && pass "per-item audio retained ($HIST_DIR/$ID.mp3)" \
  || fail "no retained audio at $HIST_DIR/$ID.mp3"

REPLAY=$(curl -sf -X POST -H 'Content-Type: application/json' -d "{\"id\":\"$ID\"}" "$D/history/replay")
RC=$?
RPOS=$(echo "$REPLAY" | json replaying)
[ "$RC" = "0" ] && [ "$RPOS" = "$ID" ] && pass "replay accepted (replaying=$RPOS)" \
  || fail "replay failed (rc=$RC, body=$REPLAY)"

echo "== Bug 1: replay of unknown id returns a clean 404 (not a silent no-op) =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"id":"deadbeef"}' "$D/history/replay")
[ "$CODE" = "404" ] && pass "unknown id → 404" || fail "unknown id → $CODE (expected 404)"

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "All smoke tests passed."
  exit 0
fi
echo "$FAILS smoke test(s) failed."
exit 1
