#!/usr/bin/env bash
# statusline.sh — Caldwell's status line for Claude Code.
#
# Renders: Caldwell mark · model · project · diff · session cost · turn
# duration · a rotating quip. Persona-aware — reads the app's config.json for
# mute + expletive mode, so the register matches the butler's mood and a muted
# dial shows a hush marker (⊘). No network, no ElevenLabs — instant and free.
#
# Note: quips stay screen-safe even in Potty Mouth mode. The status line is
# persistent and visible on a shared screen; the spoken voice is where the
# expletives live, not here.
#
# Wired in by install-hooks.sh as settings.json -> statusLine.command.

input=$(cat 2>/dev/null)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/config.json"

J() { printf '%s' "$input" | /usr/bin/jq -r "$1" 2>/dev/null; }
C() { [ -f "$CONFIG" ] && /usr/bin/jq -r "$1 // empty" "$CONFIG" 2>/dev/null; }

model=$(J '.model.display_name'); [ -z "$model" ] || [ "$model" = "null" ] && model="Claude"
dir=$(J '.workspace.current_dir'); [ -z "$dir" ] || [ "$dir" = "null" ] && dir="$PWD"
base=$(basename "$dir")
add=$(J '.cost.total_lines_added')
rem=$(J '.cost.total_lines_removed')
cost=$(J '.cost.total_cost_usd')
durms=$(J '.cost.total_duration_ms')

muted=$(C '.CALDWELL_MUTED')
potty=$(C '.CALDWELL_EXPLETIVES')

D=$'\033[2m'; R=$'\033[0m'
A=$'\033[38;5;75m'; G=$'\033[38;5;108m'; Y=$'\033[38;5;179m'; M=$'\033[38;5;245m'; HAT=$'\033[38;5;180m'
SEP="${D} · ${R}"

if [ "$muted" = "1" ]; then mark="${HAT}⊘ Caldwell${R}"; else mark="${HAT}◆ Caldwell${R}"; fi
out="${mark}${SEP}${A}${model}${R}${SEP}${base}"

if [ -n "$add" ] && [ "$add" != "null" ]; then
  [ -z "$rem" ] || [ "$rem" = "null" ] && rem=0
  out="${out}${SEP}${G}+${add}${R}/${Y}-${rem}${R}"
fi

if [ -n "$cost" ] && [ "$cost" != "null" ]; then
  c=$(printf '%.2f' "$cost" 2>/dev/null)
  out="${out}${SEP}\$${c}"
fi

if [ -n "$durms" ] && [ "$durms" != "null" ]; then
  secs=$(( durms / 1000 )); mins=$(( secs / 60 ))
  if [ "$mins" -ge 1 ]; then out="${out}${SEP}${mins}m"; else out="${out}${SEP}${secs}s"; fi
fi

polite=(
  "Right then, Sir." "Tidy work, Sir." "At your service." "Mind the edge cases."
  "Carrying on, Sir." "Quietly competent." "The usual standard, Sir."
  "Steady as she goes." "All in hand, Sir." "Rather good, this."
)
cheeky=(
  "Do try to keep up, Sir." "Bold choice, Sir." "I shan't say I told you so."
  "Marvellous. Probably." "Onward, regardless, Sir."
)
if [ "$potty" = "1" ]; then quips=( "${polite[@]}" "${cheeky[@]}" ); else quips=( "${polite[@]}" ); fi
idx=$(( 10#$(date +%M) % ${#quips[@]} ))
out="${out}${SEP}${M}${quips[$idx]}${R}"

printf '%s' "$out"
