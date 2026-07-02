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
prompt=$(printf '%s' "$input" | /usr/bin/jq -r '.prompt // ""' 2>/dev/null)

# LOCAL first-line name — cleaned first line of the prompt, ≤60 chars. This is
# the canonical default name and is ALWAYS sent (no override — sticky, so the
# first turn wins and later turns don't churn it; the LLM path is the only thing
# allowed to replace it).
local_name=$(printf '%s' "$prompt" | /usr/bin/head -n 1 \
  | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | /usr/bin/cut -c1-60)

# Best-effort session-activity ping for the Missions board. Backgrounded,
# silent, non-fatal. Carries the local first-line name so a good name lands
# immediately and by default. name_override is NOT set here — the local name is
# sticky; only the opt-in LLM titler below may overwrite it.
body=$(/usr/bin/jq -n \
  --arg sid "$sid" \
  --arg cwd "$cwd" \
  --arg name "$local_name" \
  '{session_id: $sid, phase: "working", user_message: true}
   + (if $cwd  != "" then {cwd:  $cwd}  else {} end)
   + (if $name != "" then {name: $name} else {} end)' 2>/dev/null)

if [ -n "$body" ]; then
  ( curl -sf --max-time 2 -X POST -H 'Content-Type: application/json' \
      -d "$body" http://127.0.0.1:7865/session/activity >/dev/null 2>&1 || true ) &
fi

# LLM-generated mission title — DISCLOSED OPT-IN, default OFF. Gated three ways:
#   1) the user must have turned on llm_titles_enabled in Settings,
#   2) once per session (per-session sentinel), so exactly one cheap Haiku call,
#   3) `claude` must be on PATH.
# If the flag is off we never call claude — the local name above stands.
sentinel="$HOME/.claude/.cc-named-$sid"

# Read the opt-in flag fast + non-fatally. If the daemon is down or the field is
# absent/false, `enabled` stays empty and we skip the LLM path entirely.
enabled=$(curl -sf --max-time 1 http://127.0.0.1:7865/settings 2>/dev/null \
  | /usr/bin/jq -r '.llm_titles_enabled // false' 2>/dev/null)

if [ "$enabled" = "true" ] && [ "$sid" != "default" ] && [ -n "$prompt" ] \
   && [ ! -f "$sentinel" ] && command -v claude >/dev/null 2>&1; then
  : > "$sentinel" 2>/dev/null   # name once per session, even if the call fails
  (
    # Fallback = the local first-line name, so even a failed/timed-out model
    # call leaves the (already-posted) local name in place rather than blanking.
    fallback="$local_name"

    # Run claude BACKGROUNDED with a watchdog. macOS has no `timeout(1)`, and a
    # wedged `claude -p` would otherwise linger forever holding this subshell.
    # So: launch it writing to a temp file, capture its PID, arm a watchdog
    # subshell that SIGKILLs it after 25s, and cancel the watchdog if claude
    # finishes first. No orphaned processes either way.
    out=$(/usr/bin/mktemp 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      printf '%s' "Reply with ONLY a 3 to 6 word Title Case name for this coding session. No quotes, no trailing punctuation, no preamble. Task: $prompt" \
        | /usr/bin/head -c 2000 \
        | PULSAR_NAMING=1 command claude -p --model claude-haiku-4-5-20251001 --settings '{"hooks":{}}' >"$out" 2>/dev/null &
      claude_pid=$!
      ( sleep 25; kill -9 "$claude_pid" 2>/dev/null ) &
      watchdog_pid=$!
      wait "$claude_pid" 2>/dev/null
      # claude finished (or was killed) — cancel the watchdog so it doesn't
      # linger, and reap it so no zombie/orphan remains.
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
      # name_override:true — the LLM title is the ONE caller allowed to replace
      # the sticky local seed. Still never overwrites with empty (title is
      # non-empty here).
      nbody=$(/usr/bin/jq -n --arg sid "$sid" --arg name "$title" \
        '{session_id: $sid, name: $name, name_override: true}' 2>/dev/null)
      [ -n "$nbody" ] && curl -sf --max-time 6 -X POST -H 'Content-Type: application/json' \
        -d "$nbody" http://127.0.0.1:7865/session/activity >/dev/null 2>&1 || true
    fi
  ) >/dev/null 2>&1 &
fi

exit 0
