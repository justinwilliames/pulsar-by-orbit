# Caldwell

A voice for Claude Code. Cockney butler, expletives where natural, "Sir" by default — wrapped around an ElevenLabs TTS daemon with a queue, a dashboard, and a multi-voice cast.

Forked from [tomc98/speak](https://github.com/tomc98/speak) — the engine is theirs, the persona is mine.

---

## What it does

- **Speaks aloud** via the ElevenLabs API at the end of every Claude Code turn — voice is the primary completion alert.
- **Queues across agents** — a single shared audio queue means multiple agents (or a chief-of-staff routine) never talk over each other.
- **Dashboard at `http://127.0.0.1:7865`** — animated portrait with lip-sync, transport controls, queue + history panels, **settings panel for API key + voice ID**.
- **CLI**: `./scripts/say.sh "Right then Sir"` from any terminal.

---

## 5-Minute Quickstart

**macOS only** (uses `afplay` for playback). Detailed Mac setup: [docs/SETUP_MAC.md](docs/SETUP_MAC.md).

```bash
# 1. Dependencies
brew install ffmpeg
curl -LsSf https://astral.sh/uv/install.sh | sh

# 2. Clone + start daemon (no .env needed first time)
git clone https://github.com/justinwilliames/caldwell-speak.git ~/code/caldwell-speak
cd ~/code/caldwell-speak
uv run daemon/server.py

# 3. Open the dashboard, click the gear icon, paste your ElevenLabs API key
#    and your voice ID. Save. That's it.
open http://127.0.0.1:7865

# 4. Test from another terminal
./scripts/say.sh "Right then Sir, the daemon's up. Best we crack on."
```

The dashboard's **Settings panel** (gear icon, transport-bar right) validates your inputs against ElevenLabs before saving and stores them in `config.json` (gitignored).

If you'd rather configure via terminal, `cp .env.example .env` and edit it — same effect.

---

## Configuration

Three config sources, in order of precedence (highest first):

| Source | Where | Use when |
|---|---|---|
| Real env vars | shell / launchd | CI, sysadmin overrides |
| `config.json` | repo root, gitignored | UI-managed via dashboard Settings |
| `.env` | repo root, gitignored | Dev-time defaults via terminal |

Two recognised keys: `ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID`.

### `voices.json`

Ships with Caldwell as default + 8 supporting voices. Add your own:

```json
{
  "name": "MyVoice",
  "id": "your-elevenlabs-voice-id",
  "color": "#ff6600",
  "style": "Brief description"
}
```

The daemon also falls back to the ElevenLabs API for voice names not in `voices.json`.

> **Note:** The shipped Caldwell entry uses ElevenLabs' "George" voice ID as a placeholder — British, RP, mature. It's the wrong accent (RP not Cockney) but it'll get you speaking immediately. Replace via the dashboard Settings panel once you've picked a real Caldwell voice from the [Voice Library](https://elevenlabs.io/app/voice-library) — search for *Cockney*, *London*, or *Bob Hoskins*.

---

## CLI

```bash
# Basic
./scripts/say.sh "Hello Sir"

# Choose a voice
./scripts/say.sh "Tidy bit of work, that" --voice Caldwell

# Channel tagging (for multi-agent filtering)
./scripts/say.sh "Status update" --voice Adam --channel researcher

# Priority (jumps queue)
./scripts/say.sh "Fucking 'ell, that's broken!" --priority

# Queue + history control
./scripts/say.sh --status
./scripts/say.sh --skip
./scripts/say.sh --pause
./scripts/say.sh --resume
./scripts/say.sh --clear
./scripts/say.sh --history --limit 10
./scripts/say.sh --replay <id>
```

---

## As a Claude Code Skill

Symlink or copy to `~/.claude/skills/caldwell-speak/`, then reference `$SPEAK_DIR/scripts/say.sh` in your `SKILL.md`. The shipped `SKILL.md` is the default prompt.

---

## Architecture

```
caldwell-speak/
  daemon/server.py       Starlette HTTP server — TTS, queue, SSE, settings, dashboard
  scripts/say.sh         CLI wrapper — talks to daemon, falls back to speak.py
  scripts/speak.py       Standalone TTS (no daemon needed)
  dashboard/index.html   Single-file web dashboard (incl. settings panel)
  dashboard/portraits/   Voice portraits — 3 frames each for lip-sync
  voices.json            Voice name/ID/color mappings (Caldwell + supporting cast)
  cache/                 Cached audio for history replay
  config.json            UI-managed config (API key + voice ID), gitignored
  .env                   Dev-time config (gitignored)
  SKILL.md               Claude Code skill prompt
  macos/SpeakDashboard/  Native menu-bar app (Swift, optional)
```

### API Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/speak` | Single-voice TTS |
| `POST` | `/speak/dialogue` | Multi-voice dialogue |
| `GET` | `/queue` | Queue status |
| `POST` | `/queue/skip` | Skip current |
| `POST` | `/queue/pause` | Pause playback |
| `POST` | `/queue/resume` | Resume playback |
| `POST` | `/queue/seek` | Seek within track |
| `POST` | `/queue/clear` | Clear queue |
| `GET` | `/history` | Playback history |
| `POST` | `/history/replay` | Replay cached audio |
| `GET` | `/voices` | Voice configuration |
| `GET` | `/settings` | Current API key (masked) + voice ID |
| `POST` | `/settings` | Update API key / voice ID (validates against ElevenLabs) |
| `GET` | `/events` | SSE event stream |
| `GET` | `/health` | Health check |
| `GET` | `/` | Dashboard |

---

## License

MIT — same as upstream [tomc98/speak](https://github.com/tomc98/speak).
