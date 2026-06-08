# CLAUDE.md

ElevenLabs V3 TTS skill for Claude Code. Agents speak aloud via a shared audio queue backed by an HTTP daemon.

## Running

The Caldwell menu-bar app (`macos/CaldwellDashboard`) serves the HTTP API on
`127.0.0.1:7865`. It *is* the daemon — there is no separate process to start.

```bash
# Install the app and register it to auto-launch at login
scripts/install-caldwell-app.sh            # build + copy to /Applications
scripts/install-caldwell-app-launchd.sh    # register the LaunchAgent

# Speak (the Caldwell app must be running)
scripts/say.sh "Hello"
scripts/say.sh "Hello" --voice Adam --channel my-agent
```

## Environment

Set in `.env` (copy from `.env.example`) or export in shell:

- `ELEVENLABS_API_KEY` — Required for TTS
- `ELEVENLABS_VOICE_ID` — Default voice ID (optional)
- `SPEAK_PORT` — HTTP port (default: 7865)
- `SPEAK_CACHE_DIR` — Audio cache directory (default: ./cache)

## Architecture

1. **`scripts/say.sh`** — Bash CLI. Parses args, POSTs to the app's HTTP server on 7865. No fallback — stays silent if the app is down (voice fires only when the app is running).
2. **`macos/CaldwellDashboard/`** — the SwiftUI menu-bar app and sole listener on 7865. Embedded HTTP server (`Sources/HTTPServer/`), ElevenLabs TTS, audio queue via `afplay`, phrase cache (`Sources/Engine/`), SSE, and the popover dashboard. All queue logic lives here.
3. **`voices.json`** — Voice name/ID/color mappings.
4. **`cache/`** — MP3s keyed by history ID for replay. Auto-cleaned after 24h.

## Audio Tags

V3 tags in brackets direct voice *acting* — they're stage directions, not sound effects.

**Works:** emotions (`[deadpan]`, `[conspiratorial]`), intensity shifts (`[slowly, building intensity]` → `[suddenly shouting]`), character voices (`[old timey radio announcer]`), singing (`[singing softly]`), theatrical asides, compound directions (`[whispering, conspiratorial]`).

**Doesn't work:** sound effects (`[car driving by]`), physical states (`[out of breath]`), volume control (`[even quieter]`).

## Key Design Decisions

- say.sh has no external deps — `curl` plus `python3` (JSON serialization) only. The daemon is the self-contained Swift app; TTS playback uses `afplay`.
- macOS-only — uses `afplay` for playback, `afinfo` for duration, `ffmpeg` for seeking.
- Single shared queue — all agents enqueue to one AudioQueue. Channel-based filtering prevents overlap.
- SSE, not WebSocket — simpler. Initial state on connect, then incremental events.
- MP3 validation with auto-retry — `_fetch_tts` and `_fetch_dialogue` validate response headers and retry up to 2 times on invalid audio.
