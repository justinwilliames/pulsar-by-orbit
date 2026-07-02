# CLAUDE.md

Pulsar — local-voice TTS skill for Claude Code. Agents speak aloud via a shared audio queue backed by an HTTP daemon. Voice is 100% local macOS `say`; no API key, no cost, nothing leaves the machine.

## Running

The Pulsar menu-bar app (`macos/CaldwellDashboard`) serves the HTTP API on
`127.0.0.1:7865`. It *is* the daemon — there is no separate process to start.

```bash
# Install the app and register it to auto-launch at login
scripts/install-caldwell-app.sh            # build + copy to /Applications
scripts/install-caldwell-app-launchd.sh    # register the LaunchAgent

# Speak (the Pulsar app must be running)
scripts/say.sh "Hello"
scripts/say.sh "Hello" --agent nova        # tag the line to a drone voice
```

## Environment

No API key required. Optional shell overrides:

- `SPEAK_PORT` — HTTP port (default: 7865)
- `SPEAK_CACHE_DIR` — Audio cache directory (default: ./cache)

## Architecture

1. **`scripts/say.sh`** — Bash CLI. Parses args, POSTs to the app's HTTP server on 7865. No fallback — stays silent if the app is down (voice fires only when the app is running).
2. **`macos/CaldwellDashboard/`** — the SwiftUI menu-bar app and sole listener on 7865. Embedded HTTP server (`Sources/HTTPServer/`), local TTS via `NativeVoiceClient` (calls `/usr/bin/say`, plays via `afplay`), audio queue, phrase cache (`Sources/Engine/`), SSE, and the popover dashboard. All queue logic lives here.
3. **`cache/phrases/`** — dedupe phrase cache (LRU, 50 MB) for repeated canon lines. **`cache/history/`** — per-history-item audio keyed by entry id so every history line is replayable via `/history/replay`.

## Voice — local macOS `say`, free, no key

TTS uses `NativeVoiceClient`: synthesises to a temp AIFF via `/usr/bin/say`, plays via `afplay`. Free, unlimited, no network.

- Default voice: **Daniel** (en-GB), Pulsar's character voice.
- **Do not pass `--voice`** — voice is resolved per drone character, not per call.
- `--agent <category>` tags the line to a drone; the app picks the drone's voice automatically.

## Drone Characters

Seven characters with fixed voices:

| Category  | Role        | Voice        |
|-----------|-------------|--------------|
| pulsar    | Orchestrator | Daniel (en-GB) |
| voyager   | Explorer     | Fred (en-US)   |
| sentinel  | Reviewer     | Karen (en-AU)  |
| nova      | Builder      | Samantha (en-US) |
| nebula    | Artist       | Moira (en-IE)  |
| echo      | Writer       | Tessa (en-ZA)  |
| atlas     | Generalist   | Rishi (en-IN)  |

## Sub-agent Drone Swarm

When Claude Code spawns sub-agents, each in-flight agent renders as a colour-coded drone orbiting Pulsar in the UI. Wired via Claude Code hooks:

- `SubagentStart` → `scripts/subagent-start.sh` (POST `/subagent/start`)
- `SubagentStop` → `scripts/subagent-stop.sh` (fades the drone out)

Install all hooks (7 total) with `scripts/install-hooks.sh`.

## Hooks

`scripts/install-hooks.sh` wires seven Claude Code hooks:

| Hook             | Script                    | Purpose                          |
|------------------|---------------------------|----------------------------------|
| Stop             | stop-hook.sh              | Cached canon fallback            |
| Stop             | chime.sh                  | Turn-end sound                   |
| SessionStart     | session-start-voice.sh    | Bespoke voice directive          |
| UserPromptSubmit | turn-start.sh             | Turn-start audio                 |
| SubagentStart    | subagent-start.sh         | Register drone                   |
| SubagentStop     | subagent-stop.sh          | Fade drone                       |
| statusLine       | statusline.sh             | Menu-bar status text             |

## Key Design Decisions

- `say.sh` has no external deps — `curl` plus `python3` (JSON serialisation) only.
- macOS-only — uses `afplay` for playback, `afinfo` for duration.
- Single shared queue — all agents enqueue to one AudioQueue. Channel-based filtering prevents overlap.
- SSE, not WebSocket — simpler. Initial state on connect, then incremental events.
- Phrase cache is a latency nicety (audio is free), not a spend guard.
- Requires macOS 26 (Tahoe)+, Apple Silicon.
