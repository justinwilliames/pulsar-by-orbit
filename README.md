# Caldwell

[![Build CaldwellDashboard](https://github.com/justinwilliames/caldwell-speak/actions/workflows/build.yml/badge.svg)](https://github.com/justinwilliames/caldwell-speak/actions/workflows/build.yml)

A voice for Claude Code. Alfred Pennyworth with a trucker's mouth — RP precision, butler composure, casual unflinching expletives, "Sir" by default. Wrapped around an ElevenLabs TTS daemon with a queue, a dashboard, and a launchd config that keeps Caldwell ready whenever Claude Code calls. Caldwell speaks for everything: completions, blockers, sub-agent results — the lot.

Forked from [tomc98/speak](https://github.com/tomc98/speak) — the engine is theirs, the persona is mine.

---

## What it does

- **Speaks aloud** via ElevenLabs at the end of substantive Claude Code turns — voice is the completion alert.
- **Free-tier conscious** — `SKILL.md` ships with tight rules so Caldwell speaks selectively, not on every turn.
- **Single shared queue** — sub-agents and chief-of-staff routines never overlap their spoken output, all rendered in Caldwell's voice.
- **Dashboard at `http://127.0.0.1:7865`** — Caldwell's portrait ping-pongs through 4 panels while he speaks; transport, queue, history, and a Settings panel for API key + voice ID.
- **Always-on** — optional `launchctl` config keeps the daemon running across reboots and login sessions.

---

## Install — Claude Code one-shot

Want Claude Code to drive the whole install? Open a fresh session in any directory and paste this prompt. It walks system deps, clone, daemon, API key, playback test, skill symlink, optional menu-bar app, and persistent LaunchAgents — pausing before anything destructive.

```text
Install Caldwell on this macOS machine end-to-end.

1. Check for `ffmpeg` and `uv`. If either's missing, install with `brew install ffmpeg` and the official `uv` shell installer (`curl -LsSf https://astral.sh/uv/install.sh | sh`).
2. Clone https://github.com/justinwilliames/caldwell-speak to `~/code/caldwell-speak` if it doesn't exist; otherwise `git pull` to update.
3. Start the daemon in the background (`uv run daemon/server.py` from the repo) and confirm `curl -sf http://127.0.0.1:7865/health` returns OK.
4. Open http://127.0.0.1:7865 in the browser and tell me to paste my ElevenLabs API key and voice ID into the gear-icon Settings panel. Wait until I confirm I've saved them — do NOT ask me for the key in chat (it'd end up in this session's transcript on disk).
5. Run `./scripts/say.sh "Right then Sir, the daemon is up."` to verify playback.
6. Install the Claude Code skill: `mkdir -p ~/.claude/skills && ln -s ~/code/caldwell-speak ~/.claude/skills/caldwell-speak` (skip if the symlink already exists).
7. If `sw_vers -productVersion` returns 26 or later, run `./scripts/install-caldwell-app.sh` to build and install `/Applications/Caldwell.app`.
8. Install LaunchAgents so daemon and app auto-start at every login:
   - `./scripts/install-launchd.sh` (daemon)
   - `./scripts/install-caldwell-app-launchd.sh` (menu-bar app — only if step 7 ran)
9. Print `launchctl list | grep yourorbit` so I can see both are registered.
10. Remind me to restart Claude Code so it discovers the skill.

Pause and confirm before anything that overwrites existing state (re-cloning over a working repo, overwriting `/Applications/Caldwell.app`, replacing existing LaunchAgents).
```

If a step fails, paste the error back into the same Claude Code session — it'll diagnose and recover from where it stopped.

Prefer to drive each step yourself? The manual path is below.

---

## Install — manual five steps

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

| Key | Primary store | Fallbacks (in priority order) |
|---|---|---|
| `ELEVENLABS_API_KEY` | macOS Keychain (`caldwell-speak` / `elevenlabs-api-key`) | real env var > `.env` |
| `ELEVENLABS_VOICE_ID` | `config.json` (gitignored) | real env var > `.env` |
| `SPEAK_RATE_LIMIT_PER_MIN` | env var | default `20` |
| `SPEAK_DAILY_CHAR_CAP` | env var | default `2000` |

The dashboard Settings panel writes to the primary store automatically — Keychain for the API key, `config.json` for the voice ID. The daemon migrates any `ELEVENLABS_API_KEY` it finds in `config.json` to the Keychain on startup, then clears it from the file.

### `voices.json`

Ships **Caldwell-only** — he is the voice for everything. No supporting cast, no team, no per-sub-agent voice differentiation.

> **Note:** The shipped Caldwell entry uses ElevenLabs' "George" voice ID as a placeholder — British, RP, mature. Right register; not necessarily the final pick. Replace via the dashboard Settings panel once you've chosen your Caldwell voice from the [Voice Library](https://elevenlabs.io/app/voice-library) — look for older British male, butler-leaning, RP or Estuary, capable of carrying expletives without breaking composure.

The underlying daemon retains support for multiple voices and the `/speak/dialogue` endpoint, so if you ever change your mind, add entries to `voices.json` and they'll appear in the dashboard. The persona spec and SKILL.md are intentionally Caldwell-only — sub-agents and orchestrated workflows route their spoken output through him.

---

## CLI

Basic:

```
./scripts/say.sh "Right then Sir."
./scripts/say.sh "Frankly Sir, that's fucking elegant work."
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

The `--voice` and `--channel` flags exist in the daemon but are intentionally unused in this Caldwell-only setup — Caldwell speaks for everything.

---

## Minimising ElevenLabs free-tier credit use

ElevenLabs charges per character of text-to-speech.

The biggest lever is the **phrase cache** — repeated phrases (e.g. "On it Sir.", "Pushed.", "Tests passing.") are stored locally as MP3s, keyed by exact text + voice + voice_settings. The second-and-onwards instance replays from cache: **zero credits, zero rate-limit impact, instant playback**. Lean into a small canonical Tier 1 phrase set (defined in `SKILL.md`) to maximise reuse. Cache at `cache/phrases/{hash}.mp3`, capped at 100 MB by default (`SPEAK_PHRASE_CACHE_MAX_BYTES`), LRU-pruned hourly.

Other strategies:

1. **Hard spend cap (built-in).** The daemon refuses requests beyond `SPEAK_RATE_LIMIT_PER_MIN` (default 20) or `SPEAK_DAILY_CHAR_CAP` (default 2000) — without hitting ElevenLabs. Caldwell silently drops the line; the dashboard shows a toast. Tune via env vars or set to `0` to disable.
2. **The shipped `SKILL.md` enforces credit-conscious rules** — Caldwell speaks only on substantive completions / blockers / high-stakes status, capped at one short sentence. Adjust the rules in `SKILL.md` if you want him quieter or chattier.
3. **Mute by voice command** — "quiet" / "mute" / "stop speaking" stops the skill from calling `say.sh`. Resume with "voice on" / "unmute". Zero credits spent while muted.
4. **Skip audio tags** unless they materially improve delivery (humour, tonal flips). Tags like `[dry]`, `[deadpan]` count against your character allowance.
5. **History replay is free** — replaying a cached entry from the history panel pulls from local cache, no API call.
6. **Watch your usage** at [elevenlabs.io/app/usage](https://elevenlabs.io/app/usage). Daemon-side usage available at `GET /usage`.

> **Caveat on dashboard pause:** the daemon fetches TTS audio from ElevenLabs *the moment a message is enqueued*, before playback. Dashboard pause halts playback, not the API fetch — so pausing doesn't save credits on items already queued. The "mute" instruction (which prevents enqueue at all) and the spend cap (which refuses pre-fetch) do.

---

## Security and hardening

What this setup ships with by default:

- **API key in macOS Keychain** — never in plaintext on disk. Migration from `config.json` happens automatically on first daemon startup if you upgraded from an earlier version.
- **Daemon binds to `127.0.0.1` only** — no network exposure.
- **`LocalhostGuardMiddleware`** — POST requests with non-localhost `Origin` headers get 403'd.
- **Spend caps** — per-minute rate limit and per-day character cap refuse runaway calls *before* hitting ElevenLabs.
- **Pre-commit hook** — scans staged files for `sk_<30+ chars>` and `xi-api-key:<30+ chars>` patterns. Refuses commit if a real-looking key would be added.

To enable the pre-commit hook (one-time per clone):

```
./scripts/install-githooks.sh
```

The hook lives in `.githooks/pre-commit` (version-controlled). Bypass for genuine false positives with `git commit --no-verify`.

### Future hardening — not shipped, worth knowing

| Item | Status | Why not yet |
|---|---|---|
| Notarised app | No | Not needed for personal use; ad-hoc sign + remove quarantine works |
| Daemon log rotation | No | Logs grow slowly; manual rotation if it becomes an issue |
| Cache size cap (within 24h window) | No | Auto-cleanup at 24h is sufficient in practice |
| Pre-flight secret-redaction in `say.sh` | No | SKILL.md "never speak secrets" rule is the primary defence |

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
  voices.json                  Voice name/ID/color mapping (Caldwell only)
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
| `POST` | `/settings` | Update API key (writes to Keychain) / voice ID (validates against ElevenLabs) |
| `GET` | `/usage` | Current minute call count + daily char count + caps |
| `GET` | `/events` | SSE event stream |
| `GET` | `/health` | Health check |
| `GET` | `/` | Dashboard |

---

## License

MIT — same as upstream [tomc98/speak](https://github.com/tomc98/speak).
