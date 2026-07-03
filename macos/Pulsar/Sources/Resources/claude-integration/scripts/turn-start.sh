#!/usr/bin/env bash
# turn-start.sh — Pulsar plumbing. Stamps when a turn starts, per session,
# so chime.sh can tell a long task from a quick reply and ring the right bell.
# ALSO feeds the Missions board: a UserPromptSubmit means the user just sent a
# message, so this is the ONE signal that moves a session's 7-day recency
# window.
#
# NAMING (item 3 — local-first, LLM opt-in):
#   • The SYNC /session/activity POST ALWAYS sends a LOCAL `name` = the cleaned
#     first line of the prompt. So a good, on-device name exists immediately and
#     by default. This is the canonical path — no key, no egress, no wait.
#   • ONLY if the user opted in (llm_titles_enabled) does the async LLM titler
#     run to REPLACE it, posting with `name_override:true` so the daemon accepts
#     the overwrite of the (otherwise sticky) local seed. If the flag is off we
#     do NOT invoke `claude` at all.
#
# Wired in by install-hooks.sh as a UserPromptSubmit hook.

# Recursion guard. The LLM-title step below invokes `claude` again; that nested
# run must NOT re-fire Pulsar's hooks (it would create a stray mission and could
# loop). We disable hooks on that call TWO ways: `--settings '{"hooks":{}}'` on
# the invocation, AND this env flag — set for the naming sub-run — which makes
# every Pulsar hook a no-op. Belt and suspenders.
[ -n "$PULSAR_NAMING" ] && exit 0

input=$(cat 2>/dev/null)
sid=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id // "default"' 2>/dev/null)
[ -z "$sid" ] && sid="default"
date +%s > "$HOME/.claude/.cc-turn-$sid" 2>/dev/null

cwd=$(printf '%s' "$input" | /usr/bin/jq -r '.cwd // ""' 2>/dev/null)

# Skip ephemeral / scratch sessions. A cwd under the system temp dir ($TMPDIR,
# /var/folders, /tmp) is never real project work — it's a throwaway `claude`
# invocation (e.g. Comet's dictation-cleanup CLI, which runs in $TMPDIR). Those
# would otherwise spam the Missions board with one row per dictation phrase.
case "$cwd" in
  /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*) exit 0 ;;
esac

prompt=$(printf '%s' "$input" | /usr/bin/jq -r '.prompt // ""' 2>/dev/null)

# LOCAL first-line name — cleaned first line of the prompt, ≤60 chars. This is
# the canonical default name and is ALWAYS sent (no override — sticky, so the
# first turn wins and later turns don't churn it; the LLM path is the only thing
# allowed to replace it).
local_name=$(printf '%s' "$prompt" | /usr/bin/head -n 1 \
  | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | /usr/bin/cut -c1-60)

# LIVE context for the Missions board's per-row signature (item: Session
# Signature). Two cheap, guarded git reads off the session's cwd:
#   • branch — names the LINE OF WORK, and re-sent EVERY turn so a mid-session
#     branch switch tracks (it rides this existing per-turn POST — no extra call).
#   • repo   — the repo toplevel basename, a fuller project label than the raw
#     cwd basename when they differ.
# Both are plain command substitutions BEFORE the already-backgrounded curl,
# ~5-15ms, 2>/dev/null-guarded so a wedged/absent git never blocks the turn. A
# non-git cwd simply yields empty strings, which the jq guards omit — the board
# then falls back to the cwd-basename label exactly as before.
branch=""
repo=""
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
fi

# Best-effort session-activity ping for the Missions board. Backgrounded,
# silent, non-fatal. Carries the local first-line name so a good name lands
# immediately and by default. name_override is NOT set here — the local name is
# sticky; only the opt-in LLM titler below may overwrite it. branch/repo are
# LIVE (not sticky) — the daemon takes the freshest value each turn.
body=$(/usr/bin/jq -n \
  --arg sid "$sid" \
  --arg cwd "$cwd" \
  --arg name "$local_name" \
  --arg branch "$branch" \
  --arg repo "$repo" \
  '{session_id: $sid, phase: "working", user_message: true}
   + (if $cwd    != "" then {cwd:    $cwd}    else {} end)
   + (if $name   != "" then {name:   $name}   else {} end)
   + (if $branch != "" then {branch: $branch} else {} end)
   + (if $repo   != "" then {repo:   $repo}   else {} end)' 2>/dev/null)

if [ -n "$body" ]; then
  ( curl -sf --max-time 2 -X POST -H 'Content-Type: application/json' \
      -d "$body" http://127.0.0.1:7865/session/activity >/dev/null 2>&1 || true ) &
fi

# LLM-generated mission title — DISCLOSED OPT-IN (llm_titles_enabled), default OFF.
# The title reflects the session's CURRENT TASK (drawn from the recent conversation
# in the transcript), refreshed every few turns so it tracks what the session is
# actually doing NOW — a session that pivots (e.g. build → review → bugfix) gets a
# title that keeps up, instead of being frozen on its first message. Off → we never
# call claude. Backgrounded + watchdog-reaped so it never blocks or lingers.

# Read the opt-in flag fast + non-fatally. Absent/false/daemon-down → skip.
enabled=$(curl -sf --max-time 1 http://127.0.0.1:7865/settings 2>/dev/null \
  | /usr/bin/jq -r '.llm_titles_enabled // false' 2>/dev/null)

if [ "$enabled" = "true" ] && [ "$sid" != "default" ] && command -v claude >/dev/null 2>&1; then
  # Cadence: re-title on turn 1, then every 3rd turn (4, 7, …). Enough to follow a
  # pivot quickly, without a Haiku call — or a name change — on every single turn.
  countfile="$HOME/.claude/.cc-titlecount-$sid"
  tc=$(/bin/cat "$countfile" 2>/dev/null); case "$tc" in ''|*[!0-9]*) tc=0 ;; esac
  tc=$((tc + 1)); echo "$tc" > "$countfile" 2>/dev/null
  if [ $(( (tc - 1) % 3 )) -eq 0 ]; then
  (
    fallback="$local_name"

    # CURRENT-TASK context: the most recent user+assistant text from the session
    # transcript (located by session_id), plus the just-submitted prompt as the
    # latest signal. This is what makes the title about the task, not the opener.
    tpath=$(/bin/ls -t "$HOME/.claude/projects/"*"/$sid.jsonl" 2>/dev/null | /usr/bin/head -1)
    ctx=""
    if [ -n "$tpath" ]; then
      ctx=$(/usr/bin/tail -c 200000 "$tpath" 2>/dev/null | /usr/bin/python3 -c '
import sys, json
msgs = []
for raw in sys.stdin:
    raw = raw.strip()
    if not raw or not raw.startswith("{"): continue
    try: ev = json.loads(raw)
    except Exception: continue
    t = ev.get("type")
    if t not in ("user", "assistant"): continue
    c = ev.get("message", {}).get("content")
    parts = []
    if isinstance(c, str):
        parts.append(c)
    elif isinstance(c, list):
        for ch in c:
            if isinstance(ch, dict) and ch.get("type") == "text" and ch.get("text"):
                parts.append(ch["text"])
    txt = " ".join(" ".join(p.split()) for p in parts).strip()
    if txt:
        msgs.append(("User" if t == "user" else "Assistant") + ": " + txt[:400])
print(("\n".join(msgs[-8:]))[:1800])
' 2>/dev/null)
    fi
    # Always fold in the current prompt as the newest user turn.
    ctx=$(printf '%s\nUser: %s' "$ctx" "$prompt" | /usr/bin/head -c 2200)

    out=$(/usr/bin/mktemp 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      printf '%s' "You are naming a Claude Code coding session for a compact sidebar. In 3 to 6 words, Title Case, no quotes, no trailing punctuation, no preamble, name what this session is CURRENTLY working on. Weight the MOST RECENT activity — the task may have shifted from where it began. Reply with ONLY the title.

Recent conversation:
$ctx" \
        | /usr/bin/head -c 4000 \
        | PULSAR_NAMING=1 command claude -p --model claude-haiku-4-5-20251001 --settings '{"hooks":{}}' >"$out" 2>/dev/null &
      claude_pid=$!
      ( sleep 25; kill -9 "$claude_pid" 2>/dev/null ) &
      watchdog_pid=$!
      wait "$claude_pid" 2>/dev/null
      kill "$watchdog_pid" 2>/dev/null
      wait "$watchdog_pid" 2>/dev/null

      title=$(/usr/bin/head -n 1 "$out" | /usr/bin/tr -d '"' \
        | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | /usr/bin/cut -c1-60)
      /bin/rm -f "$out" 2>/dev/null
    else
      title=""
    fi

    [ -z "$title" ] && title="$fallback"
    if [ -n "$title" ]; then
      # name_override:true — the LLM title may replace the sticky local seed (but
      # the daemon still refuses to overwrite a name the user set by hand).
      nbody=$(/usr/bin/jq -n --arg sid "$sid" --arg name "$title" \
        '{session_id: $sid, name: $name, name_override: true}' 2>/dev/null)
      [ -n "$nbody" ] && curl -sf --max-time 6 -X POST -H 'Content-Type: application/json' \
        -d "$nbody" http://127.0.0.1:7865/session/activity >/dev/null 2>&1 || true
    fi
  ) >/dev/null 2>&1 &
  fi
fi

exit 0
