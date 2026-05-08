# Caldwell

A voice for Claude Code. Alfred Pennyworth with a trucker's mouth — RP precision, butler composure, casual unflinching expletives, "Sir" by default. Wrapped around an ElevenLabs TTS daemon with a queue, a dashboard, a multi-voice cast, and a launchd config that keeps Caldwell ready whenever Claude Code calls.

Forked from [tomc98/speak](https://github.com/tomc98/speak) — the engine is theirs, the persona is mine.

---

## What it does

- **Speaks aloud** via ElevenLabs at the end of substantive Claude Code turns — voice is the completion alert.
- **Free-tier conscious** — `SKILL.md` ships with tight rules so Caldwell speaks selectively, not on every turn.
- **Queues across agents** — single shared queue means multiple agents (or chief-of-staff routines) never overlap.
- **Dashboard at `http://127.0.0.1:7865`** — Caldwell's portrait ping-pongs through 4 panels while he speaks; transport, queue, history, and a Settings panel for API key + voice ID.
- **Always-on** — optional `launchctl` config keeps the daemon running across reboots and login sessions.

---

## Install — five steps

**macOS only** (uses `afplay` for playback). Detailed Mac setup notes: [docs/SETUP_MAC.md](docs/SETUP_MAC.md).

### Step 1 — System dependencies

```
brew install ffmpeg
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
```

If `brew install` fails with a permissions error on `/opt/homebrew`, run `sudo chown -R $(whoami) /opt/homebrew` first, then retry.

Verify:

```
which uv
which ffmpeg
```

Both should return paths.

### Step 2 — Clone the repo

```
git clone https://github.com/justinwilliames/caldwell-speak.git ~/code/caldwell-speak
cd ~/code/caldwell-speak
```

### Step 3 — Start the daemon (one-off, manual)

```
uv run daemon/server.py
```

First run downloads Starlette + Uvicorn into uv's cache (one-time, ~10s), then binds to `127.0.0.1:7865`. Leave the terminal open — that's the daemon. `Ctrl-C` to stop.

For an always-running daemon (recommended after first manual test), see Step 5.

### Step 4 — Configure via the dashboard

In a second terminal:

```
open http://127.0.0.1:7865
```

The gear icon in the transport bar shows an orange dot when no API key is set. Click it, paste:

- **ElevenLabs API key** — get one at [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys).
- **Default voice ID** — add a voice from the [Voice Library](https://elevenlabs.io/app/voice-library) to your VoiceLab first, then copy the 20-character ID.

Save. The panel validates both against ElevenLabs and writes to `config.json` (gitignored).

Test:

```
./scripts/say.sh "Right then Sir, the daemon is up."
```

### Step 5 — Install as a Claude Code skill

This is what makes Caldwell speak *automatically* at the end of substantive Claude Code turns, rather than only when you run `say.sh` by hand.

```
mkdir -p ~/.claude/skills
ln -s ~/code/caldwell-speak ~/.claude/skills/caldwell-speak
```

Then **restart Claude Code** (close and reopen) so it discovers the new skill.

The shipped [`SKILL.md`](SKILL.md) defines when Caldwell speaks: only on substantive completions, blockers, or high-stakes status — not after every short reply. One short sentence per spoken line. Hard-mute on "quiet" / "mute" / "stop speaking". This is deliberately conservative to keep ElevenLabs free-tier credit usage low.

---

## Optional — native menu-bar app with floating Caldwell

The repo ships a SwiftUI menu-bar app (`macos/CaldwellDashboard/`) that gives you:

- A **menu-bar icon** (butler-bust glyph) — click for popover with queue/history/transport.
- A **floating panel** that auto-appears in the top-left corner whenever Caldwell speaks. Animated portrait with aurora halo, breathing glow rings, ripple effect on loud bursts, queued voices orbiting around him as small bubbles. Draggable, joins all macOS Spaces, doesn't steal focus.
- **Hides automatically** when audio stops and the queue is empty.

### Requirements

**macOS 26 (Tahoe) or later** — the app uses Apple's Liquid Glass APIs (`GlassEffectContainer`, `glassEffect()`) introduced in macOS 26. It will not build on Sequoia or earlier.

Swift 6.1+ — bundled with macOS 26. If you don't have it: `xcode-select --install`.

### Build and install

```
cd ~/code/caldwell-speak
./scripts/install-caldwell-app.sh
```

This compiles the binary, assembles `Caldwell.app`, ad-hoc-signs it, and copies it to `/Applications/Caldwell.app`. Then:

```
open -a Caldwell
```

The menu-bar icon appears. Click it for the popover. Caldwell's floating portrait shows up automatically when audio is playing (which won't happen until you've configured the daemon and an API key — see Steps 3 and 4 above).

### Auto-launch at login

```
./scripts/install-caldwell-app-launchd.sh
```

Registers `Caldwell.app` with `launchd` so it starts at every login. Removes itself cleanly via the printed `launchctl unload` command if you want to disable it later.

### Just rebuild after pulling updates

```
./scripts/install-caldwell-app.sh
```

Same script handles re-builds — it overwrites the existing `/Applications/Caldwell.app`.

---

## Optional — keep the daemon always running (launchd)

After Step 3 confirms the daemon works, register it with `launchd` so macOS keeps it alive across reboots and logins:

```
./scripts/install-launchd.sh
```

The script generates a plist using your current `uv` and repo paths, copies it to `~/Library/LaunchAgents/`, and loads it. Logs go to `logs/daemon.{out,err}.log` in the repo.

Check it's running:

```
launchctl list | grep caldwell-speak
curl -sf http://127.0.0.1:7865/health
```

To stop and remove:

```
./scripts/uninstall-launchd.sh
```

---

## Configuration sources

Three sources, in order of precedence (highest first):

| Source | Where | Use when |
|---|---|---|
| Real env vars | shell / launchd | CI, sysadmin overrides |
| `config.json` | repo root, gitignored | UI-managed via dashboard Settings |
| `.env` | repo root, gitignored | Dev-time defaults via terminal |

Two recognised keys: `ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID`.

### `voices.json`

Ships **Caldwell-only**. The dashboard shows just him; no supporting cast. Add your own voices if you need them:

```json
{
  "name": "MyVoice",
  "id": "your-elevenlabs-voice-id",
  "color": "#ff6600",
  "style": "Brief description"
}
```

The daemon also falls back to the ElevenLabs API for voice names not in `voices.json` — so multi-agent setups can call `--voice Adam` even without an explicit entry. Names without a `voices.json` entry won't have a portrait or dashboard tile but will play through the queue.

> **Note:** The shipped Caldwell entry uses ElevenLabs' "George" voice ID as a placeholder — British, RP, mature. Right register; not necessarily the final pick. Replace via the dashboard Settings panel once you've chosen your Caldwell voice from the [Voice Library](https://elevenlabs.io/app/voice-library) — look for older British male, butler-leaning, RP or Estuary, capable of carrying expletives without breaking composure.

---

## CLI

Basic:

```
./scripts/say.sh "Right then Sir."
```

Pick a voice:

```
./scripts/say.sh "Frankly Sir, that's fucking elegant work" --voice Caldwell
```

Channel tagging (multi-agent filtering):

```
./scripts/say.sh "Status update" --voice Adam --channel researcher
```

Priority (jumps the queue):

```
./scripts/say.sh "I'm afraid we have a problem, Sir." --priority
```

Queue and history control:

```
./scripts/say.sh --status
./scripts/say.sh --skip
./scripts/say.sh --pause
./scripts/say.sh --resume
./scripts/say.sh --clear
./scripts/say.sh --history --limit 10
./scripts/say.sh --replay <id>
```

---

## Minimising ElevenLabs free-tier credit use

ElevenLabs charges per character of text-to-speech. Strategies:

1. **The shipped `SKILL.md` already enforces credit-conscious rules** — Caldwell speaks only on substantive completions / blockers / high-stakes status, capped at one short sentence. Adjust the rules in `SKILL.md` if you want him quieter or chattier.
2. **Mute by voice command** — "quiet" / "mute" / "stop speaking" stops the skill from calling `say.sh`. Resume with "voice on" / "unmute". Zero credits spent while muted.
3. **Skip audio tags** unless they materially improve delivery (humour, tonal flips). Tags like `[dry]`, `[deadpan]` count against your character allowance.
4. **History replay is free** — replaying a cached entry from the history panel pulls from local cache, no API call.
5. **Watch your usage** at [elevenlabs.io/app/usage](https://elevenlabs.io/app/usage).

> **Caveat on dashboard pause:** the daemon fetches TTS audio from ElevenLabs *the moment a message is enqueued*, before playback. Dashboard pause halts playback, not the API fetch — so pausing doesn't save credits on items already queued. The "mute" instruction (which prevents enqueue at all) does.

---

## Architecture

```
caldwell-speak/
  daemon/server.py             Starlette HTTP server — TTS, queue, SSE, settings, dashboard
  scripts/say.sh               CLI wrapper — talks to daemon, falls back to speak.py
  scripts/speak.py             Standalone TTS (no daemon needed)
  scripts/install-launchd.sh   Register the daemon with launchd for always-on
  scripts/uninstall-launchd.sh Reverse the above
  dashboard/index.html         Single-file web dashboard (incl. settings panel)
  dashboard/portraits/         Voice portraits — Caldwell ships with 4 panels for ping-pong cycle
  voices.json                  Voice name/ID/color mappings (Caldwell + supporting cast)
  cache/                       Cached audio for history replay (24h TTL)
  config.json                  UI-managed config (API key + voice ID), gitignored
  .env                         Dev-time config (gitignored)
  logs/                        launchd daemon stdout/stderr (gitignored)
  SKILL.md                     Claude Code skill prompt — credit-conscious by default
  macos/CaldwellDashboard/     Native menu-bar app (Swift, requires macOS 26)
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
