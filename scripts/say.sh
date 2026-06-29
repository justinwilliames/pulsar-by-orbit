#!/usr/bin/env bash
# say.sh — TTS via the Caldwell app's HTTP server on 127.0.0.1:7865.
# No fallback: if the app (daemon) is down, say.sh stays silent. Voice fires
# only when the Caldwell app is running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env if present (real env vars win via ${VAR:-} pattern)
if [[ -f "$REPO_ROOT/.env" ]]; then
  while IFS='=' read -r key value; do
    key="${key%%#*}"          # strip inline comments
    key="${key// /}"          # strip spaces
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="${value%\"}"       # strip surrounding quotes
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    : "${!key:=$value}"       # only set if not already in env
    export "$key"
  done < "$REPO_ROOT/.env"
fi

SPEAK_PORT="${SPEAK_PORT:-7865}"
DAEMON="http://127.0.0.1:$SPEAK_PORT"

# Parse arguments
TEXT=""
VOICE=""
CHANNEL=""
PRIORITY=false
CACHEABLE=false
ACTION=""
LIMIT=50
REPLAY_ID=""
SETUP_VALUE=""
CANON_CONTEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --voice)         VOICE="$2"; shift 2 ;;
    --channel)       CHANNEL="$2"; shift 2 ;;
    --priority)      PRIORITY=true; shift ;;
    --cacheable)     CACHEABLE=true; shift ;;
    --canon)         ACTION="canon"; CANON_CONTEXT="$2"; shift 2 ;;
    --status)        ACTION="status"; shift ;;
    --skip)          ACTION="skip"; shift ;;
    --clear)         ACTION="clear"; shift ;;
    --pause)         ACTION="pause"; shift ;;
    --resume)        ACTION="resume"; shift ;;
    --history)       ACTION="history"; shift ;;
    --limit)         LIMIT="$2"; shift 2 ;;
    --replay)        ACTION="replay"; REPLAY_ID="$2"; shift 2 ;;
    --usage)         ACTION="usage"; shift ;;
    --settings)      ACTION="settings"; shift ;;
    --set-api-key)   ACTION="set-api-key"; SETUP_VALUE="$2"; shift 2 ;;
    --set-voice-id)  ACTION="set-voice-id"; SETUP_VALUE="$2"; shift 2 ;;
    --mute)          ACTION="set-muted"; SETUP_VALUE="true"; shift ;;
    --unmute)        ACTION="set-muted"; SETUP_VALUE="false"; shift ;;
    -*)              echo "Unknown option: $1" >&2; exit 1 ;;
    *)               TEXT="$1"; shift ;;
  esac
done

# Check daemon health
daemon_up() {
  curl -sf --connect-timeout 1 "$DAEMON/health" >/dev/null 2>&1
}

# Build JSON body with safe serialization
json_body() {
  python3 -c "
import json, sys
d = {}
if sys.argv[1]: d['channel'] = sys.argv[1]
print(json.dumps(d))
" "$CHANNEL"
}

# Dispatch actions
case "${ACTION:-speak}" in
  status)
    curl -sf "$DAEMON/queue" | python3 -m json.tool
    ;;
  skip)
    curl -sf -X POST "$DAEMON/queue/skip"
    ;;
  clear)
    curl -sf -X POST -H "Content-Type: application/json" -d "$(json_body)" "$DAEMON/queue/clear"
    ;;
  pause)
    curl -sf -X POST -H "Content-Type: application/json" -d "$(json_body)" "$DAEMON/queue/pause"
    ;;
  resume)
    curl -sf -X POST -H "Content-Type: application/json" -d "$(json_body)" "$DAEMON/queue/resume"
    ;;
  history)
    curl -sf "$DAEMON/history?limit=$LIMIT" | python3 -m json.tool
    ;;
  replay)
    REPLAY_BODY=$(python3 -c "import json, sys; print(json.dumps({'id': sys.argv[1]}))" "$REPLAY_ID")
    curl -sf -X POST -H "Content-Type: application/json" \
      -d "$REPLAY_BODY" "$DAEMON/history/replay"
    ;;
  usage)
    curl -sf "$DAEMON/usage" | python3 -m json.tool
    ;;
  settings)
    curl -sf "$DAEMON/settings" | python3 -m json.tool
    ;;
  set-api-key)
    [[ -z "$SETUP_VALUE" ]] && { echo "Usage: say.sh --set-api-key <key>" >&2; exit 1; }
    BODY=$(python3 -c "import json, sys; print(json.dumps({'api_key': sys.argv[1]}))" "$SETUP_VALUE")
    curl -sf -X POST -H "Content-Type: application/json" -d "$BODY" "$DAEMON/settings" | python3 -m json.tool
    ;;
  set-voice-id)
    [[ -z "$SETUP_VALUE" ]] && { echo "Usage: say.sh --set-voice-id <20-char-id>" >&2; exit 1; }
    BODY=$(python3 -c "import json, sys; print(json.dumps({'voice_id': sys.argv[1]}))" "$SETUP_VALUE")
    curl -sf -X POST -H "Content-Type: application/json" -d "$BODY" "$DAEMON/settings" | python3 -m json.tool
    ;;
  set-muted)
    BODY=$(python3 -c "import json, sys; print(json.dumps({'muted': sys.argv[1] == 'true'}))" "$SETUP_VALUE")
    curl -sf -X POST -H "Content-Type: application/json" -d "$BODY" "$DAEMON/settings" | python3 -m json.tool
    ;;
  canon)
    # Context-aware cached-canon pick. Daemon picks a phrase tagged with the
    # given context that's actually in cache, then enqueues it. Cache-only —
    # never spends ElevenLabs credit. Stays silent (HTTP 204) if nothing
    # cached matches the context. Use this for turn-end pings instead of
    # hand-writing canon strings that might miss the cache.
    #
    # Known contexts: push, tests-pass, build-pass, found, fail, done,
    # start, ack, reassure, neutral.
    if ! daemon_up; then
      exit 0
    fi
    BODY=$(python3 -c "import json, sys; print(json.dumps({'context': sys.argv[1]}))" "$CANON_CONTEXT")
    curl -sf --max-time 3 -X POST -H "Content-Type: application/json" \
      -d "$BODY" "$DAEMON/canon/pick" >/dev/null 2>&1 || true
    exit 0
    ;;
  speak)
    [[ -z "$TEXT" ]] && {
      echo "Usage: say.sh \"text\" [--voice NAME] [--channel CH] [--priority] [--cacheable]" >&2
      echo "       say.sh --status | --skip | --clear | --pause | --resume" >&2
      echo "       say.sh --history [--limit N] | --replay ID" >&2
      echo "       say.sh --usage | --settings" >&2
      echo "       say.sh --set-api-key sk_... | --set-voice-id <20-char-id>" >&2
      echo "       say.sh --mute | --unmute" >&2
      echo "" >&2
      echo "Add --cacheable for any line generic enough to fire again" >&2
      echo "on a different turn (\"Pushed.\", \"Sorted Sir.\", \"Tests passing.\")." >&2
      echo "Context-specific lines should never be cached." >&2
      exit 1
    }

    # Daemon is the Swift app. If it's not running, stay silent — never
    # fall back to direct ElevenLabs calls. Voice fires ONLY when the app
    # is open (popover + voice are a single feature; no daemon = no voice
    # = no spend).
    if ! daemon_up; then
      exit 0
    fi

    # Build JSON body using python3 for safe serialization
    BODY=$(python3 -c "
import json, sys
d = {'text': sys.argv[1]}
if sys.argv[2]: d['voice'] = sys.argv[2]
if sys.argv[3]: d['channel'] = sys.argv[3]
if sys.argv[4] == 'true': d['priority'] = True
if sys.argv[5] == 'true': d['cacheable'] = True
print(json.dumps(d))
" "$TEXT" "$VOICE" "$CHANNEL" "$PRIORITY" "$CACHEABLE")

    # --max-time guards against curl hanging on a stale keep-alive
    # connection; output redirected to /dev/null so Claude Code's Bash
    # tool sees stdout close immediately. Explicit `exit 0` ensures the
    # shell terminates the moment curl returns.
    curl -sf --max-time 3 -X POST -H "Content-Type: application/json" \
      -d "$BODY" "$DAEMON/speak" >/dev/null 2>&1 || true
    exit 0
    ;;
esac
