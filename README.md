# Caldwell

[![Build CaldwellDashboard](https://github.com/justinwilliames/caldwell-speak/actions/workflows/build.yml/badge.svg)](https://github.com/justinwilliames/caldwell-speak/actions/workflows/build.yml)

A voice for Claude Code. Alfred Pennyworth as the base, with two registers — **Polite** (butler-formal RP, no swearing) or **Potty Mouth** (RP precision plus unflinching expletives where the moment earns them) — switchable from the menu-bar Settings panel. "Sir" in both modes. Wrapped around an ElevenLabs TTS daemon with a queue, a macOS 26 menu-bar app, a phrase cache that makes repeated lines free, and a launchd config that keeps Caldwell ready whenever Claude Code calls. Caldwell speaks for everything: completions, blockers, sub-agent results — the lot.

Forked from [tomc98/speak](https://github.com/tomc98/speak) — the engine is theirs, the persona is mine.

---

## What it does

- **Speaks aloud** via ElevenLabs at the end of every Claude Code turn by default — `SKILL.md` ships bias-flipped, so the voice acts as a turn-end ping. Suppression rules cover mute, repetition, and code-heavy replies; the rest of the time he speaks.
- **Free-tier survivable via the phrase cache** — reusable lines (any tier — "Pushed, Sir." through "I'm afraid the tests are failing — log's in the chat.") get cached locally as MP3s and replay for **zero credits**. Cache writes are **opt-in**: Caldwell-the-skill passes `--cacheable` for any line he'd happily fire again on a different turn, never for context-specific one-shots. Spend caps and a daily char budget gate everything that misses the cache.
- **Polite / Potty Mouth toggle** — single segmented picker at the top of the menu-bar Settings panel. Persisted to `config.json` as `CALDWELL_EXPLETIVES`, surfaced via `GET /settings`, read by Caldwell-the-skill at session start.
- **Single shared queue** — sub-agents and chief-of-staff routines never overlap their spoken output, all rendered in Caldwell's voice.
- **macOS 26 menu-bar app** (`Caldwell.app`) — three-tab popover (History / Cache / Settings) plus an animated floating portrait that auto-appears top-left when Caldwell speaks. Mute toggle in the popover header switches the menu-bar glyph itself, so AFK mute is one click.
- **Always-on** — an optional `launchctl` config keeps the menu-bar app running across reboots and login sessions.

---

## Install — Claude Code one-shot

Want Claude Code to drive the whole install? Open a fresh session in any directory and paste this prompt. It walks system deps, clone, Swift app install, API key setup, warm-cache, skill symlink, and the single LaunchAgent that keeps Caldwell on `127.0.0.1:7865` — pausing before anything destructive.

```text
Install Caldwell on this macOS machine end-to-end.

1. Check for `ffmpeg` and `swift`. If `ffmpeg` is missing, install it with `brew install ffmpeg`. If `swift` is missing, run `xcode-select --install`.
2. Clone https://github.com/justinwilliames/caldwell-speak to `~/code/caldwell-speak` if it doesn't exist; otherwise `git pull` to update.
3. Check `sw_vers -productVersion`. If it's below 26, stop and tell me the single-binary Swift app install isn't supported on this machine yet. If it's 26 or later, run `./scripts/install-caldwell-app.sh` and `./scripts/install-caldwell-app-launchd.sh`, then confirm `curl -sf http://127.0.0.1:7865/health` returns OK. The LaunchAgent script should retire any old `team.yourorbit.caldwell-speak` Python daemon agent.
4. Ask me for my ElevenLabs API key and voice ID, then save them via `./scripts/say.sh --set-api-key sk_...` and `./scripts/say.sh --set-voice-id <20-char-id>`. Caldwell writes the key to macOS Keychain and the voice ID to `config.json`. I can also paste them into the menu-bar Settings tab — same destination.
5. Run `./scripts/warm-cache.sh` once to pre-cache the 25 canonical Tier 0 phrases (Polite + Potty Mouth). This burns ~475 chars of the monthly free-tier 10,000 budget once, but means every Caldwell turn-end ping from day one is a free cached replay. The script is silent (cache_only mode skips audio playback during install), idempotent (already-cached phrases skipped), and takes ~100 seconds with the rate-limit-friendly pacing.
6. Run `./scripts/say.sh "Right then Sir, the Swift app is up."` to verify playback.
7. Install the Claude Code skill: `mkdir -p ~/.claude/skills && ln -s ~/code/caldwell-speak ~/.claude/skills/caldwell-speak` (skip if the symlink already exists).
8. Print `launchctl list | grep yourorbit` so I can see the app LaunchAgent is registered and the old daemon is gone.
9. Tell me to open the menu-bar Caldwell → Settings tab and pick the persona mode (default is Potty Mouth; flip to Polite if I'd rather no swearing).
10. Optional but recommended for Caldwell to actually fire on every turn: tell me to add a "Voice — fire `say.sh` at every turn-end" section to my `~/.claude/CLAUDE.md` mirroring the one in this repo's [`SKILL.md`](SKILL.md). The skill description alone is descriptive, not enforcing — the CLAUDE.md instruction is what makes it load-bearing.
11. Remind me to restart Claude Code so it discovers the skill and re-reads CLAUDE.md.

Pause and confirm before anything that overwrites existing state (re-cloning over a working repo, overwriting `/Applications/Caldwell.app`, replacing existing LaunchAgents).
```

If a step fails, paste the error back into the same Claude Code session — it'll diagnose and recover from where it stopped.

Prefer to drive each step yourself? The manual path is below.

---

## Install — manual five steps

**macOS only** (uses `afplay` for playback). The single-binary install path below requires macOS 26+ because `Caldwell.app` now owns the HTTP server on `127.0.0.1:7865`. Detailed Mac setup notes: [docs/SETUP_MAC.md](docs/SETUP_MAC.md).

### Step 1 — System dependencies

```
brew install ffmpeg
```

If `swift` is missing, run:

```
xcode-select --install
```

If `brew install` fails with a permissions error on `/opt/homebrew`, run `sudo chown -R $(whoami) /opt/homebrew` first, then retry.

Verify:

```
which ffmpeg
which swift
```

Both should return paths.

### Step 2 — Clone the repo

```
git clone https://github.com/justinwilliames/caldwell-speak.git ~/code/caldwell-speak
cd ~/code/caldwell-speak
```

### Step 3 — Install the Swift app and register it at login

```
./scripts/install-caldwell-app.sh
./scripts/install-caldwell-app-launchd.sh
curl -sf http://127.0.0.1:7865/health
```

This builds `Caldwell.app`, loads the app LaunchAgent, retires any old `team.yourorbit.caldwell-speak` Python daemon agent, and makes the Swift app the sole listener on `127.0.0.1:7865`.

### Step 4 — Configure the API key + voice ID

There are two equivalent ways:

**Via CLI (works on any macOS):**

```
./scripts/say.sh --set-api-key sk_...
./scripts/say.sh --set-voice-id <20-char-id>
```

Caldwell writes the key to macOS Keychain and the voice ID to `config.json`, validating both against ElevenLabs on save.

**Via the menu-bar app's Settings tab (macOS 26 only):**

Click the menu-bar icon → Settings, paste the API key and voice ID, hit Save. Same destinations.

**Where to get them:**

- ElevenLabs API key — [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys)
- Voice ID — add a voice from the [Voice Library](https://elevenlabs.io/app/voice-library) to your VoiceLab first, then copy the 20-character ID

### Step 5 — Warm the cache, test playback, and install as a Claude Code skill

```
./scripts/warm-cache.sh
./scripts/say.sh "Right then Sir, the Swift app is up."
mkdir -p ~/.claude/skills
ln -s ~/code/caldwell-speak ~/.claude/skills/caldwell-speak
```

This is what makes Caldwell speak *automatically* at the end of substantive Claude Code turns, rather than only when you run `say.sh` by hand.

Then **restart Claude Code** (close and reopen) so it discovers the new skill.

The shipped [`SKILL.md`](SKILL.md) is **bias-flipped**: Caldwell speaks at the end of every turn by default, picks a tier (presence / substantive / detailed alert), and stays silent only on explicit suppression — mute, repeating yourself, code-heavy reply, spend cap rejected, or trivial bookkeeping. At session start he runs two `curl` calls — one against `GET /settings` to learn the active register (Polite vs Potty Mouth), one against `GET /cache/phrases?sort=popular` to load the canon of free-to-replay lines — and prefers cached canon over inventing new lines.

The credit envelope is preserved by the cache, the daily char cap, and the per-minute rate limit, not by silence. Adjust the suppression list in `SKILL.md` if you want him quieter; toggle Polite mode in the menu-bar app if you want the swearing dial off without losing the cadence.

---

## Native menu-bar app with floating Caldwell

The repo ships a SwiftUI menu-bar app (`macos/CaldwellDashboard/`) that gives you:

- A **menu-bar icon** (butler-bust glyph) — click for the popover.
- A **floating panel** that auto-appears in the top-left corner whenever Caldwell speaks. Animated portrait with aurora halo, breathing glow rings, ripple effect on loud bursts, queued voices orbiting around him as small bubbles. Draggable, joins all macOS Spaces, doesn't steal focus, hides automatically when the queue empties.
- **Five-tab popover** — Now Playing, Queue, History, **Cache**, Settings.
  - **Cache** lists every cached phrase with text, play count, last-played-at, and on-disk size; row-level free-replay button; sort by Recent or Popular; footer shows total bytes used.
  - **Settings** has a Polite / Potty Mouth segmented picker at the top (saves on toggle, persists to `config.json`), then the API key + voice ID fields and the daily usage bars.

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

The menu-bar icon appears. Click it for the popover. Caldwell's floating portrait shows up automatically when audio is playing (which won't happen until you've configured the app and an API key — see Steps 3 and 4 above).

### Auto-launch at login

```
./scripts/install-caldwell-app-launchd.sh
```

Registers `Caldwell.app` with `launchd` so it starts at every login. Removes itself cleanly via the printed `launchctl unload` command if you want to disable it later.
If a legacy `team.yourorbit.caldwell-speak` Python daemon LaunchAgent exists, the script unloads and disables it first.

### Just rebuild after pulling updates

```
./scripts/install-caldwell-app.sh
```

Same script handles re-builds — it overwrites the existing `/Applications/Caldwell.app`.

---

## Configuration sources

| Key | Primary store | Fallbacks (in priority order) | Notes |
|---|---|---|---|
| `ELEVENLABS_API_KEY` | macOS Keychain (`caldwell-speak` / `elevenlabs-api-key`) | real env var > `.env` | |
| `ELEVENLABS_VOICE_ID` | `config.json` (gitignored) | real env var > `.env` | |
| `CALDWELL_EXPLETIVES` | `config.json` (gitignored) | real env var > default `"1"` | `"1"` = Potty Mouth, `"0"` = Polite |
| `SPEAK_RATE_LIMIT_PER_MIN` | env var | default `20` | Per-minute call cap |
| `SPEAK_DAILY_CHAR_CAP` | env var | default `2000` | Per-day character cap |
| `SPEAK_PHRASE_CACHE_MAX_BYTES` | env var | default `104857600` (100 MB) | Phrase cache size budget |

The menu-bar app's Settings tab and the `say.sh --set-*` CLI flags both write to the primary store — Keychain for the API key, `config.json` for the voice ID and the persona mode. The daemon migrates any `ELEVENLABS_API_KEY` it finds in `config.json` to the Keychain on startup, then clears it from the file.

### Persona modes — Polite vs Potty Mouth

Caldwell ships with two registers, switchable from the **Settings** tab of the menu-bar app (segmented picker at the top, saves on toggle).

| Mode | `CALDWELL_EXPLETIVES` | Register |
|---|---|---|
| **Potty Mouth** (default) | `"1"` | Alfred Pennyworth with a trucker's mouth — RP precision, butler composure, unflinching expletives where the moment earns them. The contrast does the comedy. |
| **Polite** | `"0"` | Alfred Pennyworth straight — same RP precision, same butler composure, same dry asides, same willingness to call out a bad idea. Just no swearing. |

The toggle is a contract Caldwell-the-skill respects, not a daemon-side filter. At session start the skill runs `curl -s http://127.0.0.1:7865/settings`, reads `expletives_enabled`, and composes accordingly for the rest of the session. See [`SKILL.md`](SKILL.md) for the per-tier examples in both modes.

### Phrase cache — the credit lever

The daemon content-addresses every cache-eligible TTS request as `sha256(text + voice_id + voice_settings)` and stashes the resulting MP3 at `cache/phrases/{hash}.mp3` with a sidecar `{hash}.json` holding the original text, voice label, first-cached timestamp, last-played timestamp, and play count. The cache is LRU-pruned hourly to stay under `SPEAK_PHRASE_CACHE_MAX_BYTES` (100 MB default).

**Cache writes are opt-in, judgment-based.** `POST /speak` accepts `cacheable: bool` (default `false`); `say.sh` accepts `--cacheable`. The skill decides reusability per call — there's **no length cap**. The test is one question: *"would this exact line make sense tomorrow on a different turn?"* If yes, cache. If no, don't.

A 60-char Tier 2 line like `"I'm afraid the tests are failing — log's in the chat."` is just as cacheable as `"Pushed, Sir."` — both recur generically. The previous 40-char hard cap was a crude proxy that excluded legitimately reusable longer phrases.

**Cache reads always check, regardless of the flag.** A previously-cached canonical phrase still plays free from disk on subsequent requests. The flag only governs writes.

`SKILL.md` is the contract: Caldwell-the-skill flags any line he'd happily fire again on a different turn (across all four tiers) with `--cacheable`, and lets context-specific lines (file names, feature mentions, session-specific findings) run as one-shots. The full canon and scenario list is in [`SKILL.md`](SKILL.md#caching--the-test-is-reusability-not-tier-or-length).

Admin endpoints for cleanup:

| Method | Path | Description |
|---|---|---|
| `DELETE` | `/cache/phrases/{key}` | Purge a single cached phrase by hash |
| `POST` | `/cache/clear` | Wipe every cached phrase (destructive) |

The `Cache` tab in the menu-bar popover renders the live list with sort, popular-first ordering, and per-row replay buttons.

### `voices.json`

Ships **Caldwell-only** — he is the voice for everything. No supporting cast, no team, no per-sub-agent voice differentiation.

> **Note:** The shipped Caldwell entry uses ElevenLabs' "George" voice ID as a placeholder — British, RP, mature. Right register; not necessarily the final pick. Replace via the menu-bar Settings tab or `say.sh --set-voice-id <id>` once you've chosen your Caldwell voice from the [Voice Library](https://elevenlabs.io/app/voice-library) — look for older British male, butler-leaning, RP or Estuary, capable of carrying expletives without breaking composure.

The underlying daemon retains support for multiple voices and the `/speak/dialogue` endpoint, so if you ever change your mind, add entries to `voices.json`. The persona spec and SKILL.md are intentionally Caldwell-only — sub-agents and orchestrated workflows route their spoken output through him.

---

## CLI

Basic:

```
./scripts/say.sh "Right then Sir."
./scripts/say.sh "Frankly Sir, that's fucking elegant work."
```

Cacheable canonical phrase (writes to phrase cache; default is no-cache):

```
./scripts/say.sh "Pushed, Sir." --cacheable
./scripts/say.sh "Tests passing." --cacheable
```

Pass `--cacheable` for any line you'd happily fire again on a different turn — generic states, reusable observations, character beats not tied to a specific moment. Context-specific lines (file names, feature mentions, session-specific findings) should run without the flag. There's no length cap; the test is contextual reusability, not character count.

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

Setup and runtime config (replaces the dropped web dashboard's settings panel — same destinations, just over the wire):

```
./scripts/say.sh --set-api-key sk_...        # writes to macOS Keychain
./scripts/say.sh --set-voice-id <20-char-id> # writes to config.json
./scripts/say.sh --mute                       # AFK silence; daemon refuses /speak
./scripts/say.sh --unmute                     # back on
./scripts/say.sh --polite                     # persona: no swearing
./scripts/say.sh --potty                      # persona: heavy expletives (default)
./scripts/say.sh --settings                   # show current state
./scripts/say.sh --usage                      # daily/monthly/ElevenLabs usage stats
```

The `--voice` and `--channel` flags exist in the daemon but are intentionally unused in this Caldwell-only setup — Caldwell speaks for everything.

---

## Minimising ElevenLabs free-tier credit use

ElevenLabs charges per character of text-to-speech. The bias-flipped `SKILL.md` says Caldwell speaks at the end of every turn — without a credit story behind that default, the free tier evaporates in a day. Three layers keep it survivable:

### 1. Phrase cache — the primary credit-saver

Canonical generic phrases get cached at `cache/phrases/{hash}.mp3` (with `{hash}.json` sidecars for text + play counts) and replay for **zero credits, zero rate-limit impact, instant playback**. Cache reads always check; a previously-cached line never re-bills.

**Cache writes are opt-in to keep the canon clean.** `POST /speak` requires `cacheable: true` (and `say.sh` requires `--cacheable`) before the daemon writes a new entry. Without the flag, the audio plays once and is discarded — no cache pollution from one-shot context-specific lines like "Cache panel's wired in, Sir."

The test is reusability, not length: any line across any tier gets cached if it'd plausibly fire again on a different turn. A 60-char generic Tier 2 line like `"Right then Sir, deploy's gone through clean."` is just as cacheable as `"Pushed."`. The previous 40-char hard cap was a crude proxy and has been removed.

`SKILL.md` is the contract: Caldwell-the-skill flags reusable lines (across all tiers) with `--cacheable`, and lets context-specific lines (file names, feature mentions, session-specific findings) run as one-shots. At session start he also runs:

```bash
curl -s 'http://127.0.0.1:7865/cache/phrases?sort=popular&limit=30'
```

…to load the live cached canon and prefer those over composing fresh lines. The popular list is sorted descending by play count, so the highest-leverage reuses surface first.

The same data renders in the **Cache tab** of the menu-bar popover with per-row replay buttons (replays via `POST /cache/play` — same zero-credit path). Per-row purge is available via `DELETE /cache/phrases/{key}`.

Cache is LRU-pruned hourly to stay under `SPEAK_PHRASE_CACHE_MAX_BYTES` (100 MB default — typically 1000+ short phrases at ~30 KB each).

### 2. Persona mode reduces inventiveness drift

Polite mode tends to compress the working vocabulary (no expletive flourishes, fewer one-off variations), which means more cache hits over time. If you're aggressively credit-bound, Polite mode + a saturated cache approaches near-zero ongoing cost.

### 3. Spend caps refuse before fetching

Per-minute rate limit (`SPEAK_RATE_LIMIT_PER_MIN`, default 20) and per-day char cap (`SPEAK_DAILY_CHAR_CAP`, default 2000) are checked **before** the daemon hits ElevenLabs on a cache miss. When either is exceeded, the daemon returns 429 and the line is silently dropped — credits stay safe even if the skill tries to be chatty. Both can be tuned via env vars or set to `0` to disable.

Cache hits **bypass** the spend cap entirely — repeated phrases are always free regardless of the day's char count.

### Other levers

- **Mute by voice command** — say "quiet" / "mute" / "head down" / "I'm in a meeting" and `SKILL.md` stops the skill from calling `say.sh` at all. Zero credits while muted; resume with "voice on" / "unmute".
- **Skip audio tags** — tags like `[dry]`, `[deadpan]` consume characters. Use them only when delivery genuinely needs the direction.
- **History replay is free** — the History panel's replay button pulls from the same cache, no API call.
- **Daemon-side usage at `GET /usage`** — current minute call count, daily char count, and the active caps. Settings panel shows the live bars. ElevenLabs-side usage at [elevenlabs.io/app/usage](https://elevenlabs.io/app/usage).

### Caveats

- **Pause halts playback, not the API fetch.** The daemon fetches TTS audio from ElevenLabs the moment a message is enqueued — pausing playback doesn't refund credits on items already queued. The menu-bar Mute toggle (or `say.sh --mute`) prevents enqueue at all and is the right tool for AFK saves; the spend cap refuses pre-fetch when daily/monthly limits are hit.
- **Persona mode is a contract, not a filter.** When Polite mode is on, Caldwell-the-skill is told to stay clean, but the daemon doesn't sanitize the text. If a session ignores the instruction the audio's already paid for. Hard daemon-side regex enforcement isn't shipped — Claude-side compliance is the contract.

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
| Daemon-side expletive regex when Polite mode is on | No | Persona mode is a contract Caldwell-the-skill respects; add daemon enforcement only if slippage is observed |

---

## Architecture

```
caldwell-speak/
  daemon/server.py                   Starlette HTTP server — TTS, queue, cache, SSE, settings
  scripts/say.sh                     CLI wrapper — talks to daemon, falls back to speak.py
  scripts/speak.py                   Standalone TTS (no daemon needed)
  scripts/install-launchd.sh         Register the daemon with launchd for always-on
  scripts/uninstall-launchd.sh       Reverse the above
  scripts/install-caldwell-app.sh    Build + install the macOS menu-bar app
  scripts/install-caldwell-app-launchd.sh  Auto-launch the app at login (kills duplicate first)
  assets/portraits/                  Caldwell portrait images (4 frames; served via /portraits/)
  voices.json                        Voice name/ID/color mapping (Caldwell only)
  cache/phrases/{hash}.mp3           Phrase cache — free replays, content-addressed by text+voice
  cache/phrases/{hash}.json          Sidecar metadata (text, voice, timestamps, play count)
  cache/{history_id}.mp3             Per-history-entry audio (24h TTL) for /history/replay
  config.json                        UI-managed config (voice ID, persona mode), gitignored
  .env                               Dev-time config (gitignored)
  logs/                              launchd daemon stdout/stderr (gitignored)
  SKILL.md                           Claude Code skill prompt — bias-flipped, dual-mode, cache-aware
  macos/CaldwellDashboard/Sources/   Native menu-bar app (Swift 6.1, requires macOS 26)
    Models/                            Codable structs (CachedPhrase, HistoryEntry, ...)
    Networking/DaemonAPI.swift         REST client for daemon endpoints
    ViewModels/DashboardViewModel.swift  @Observable state container
    Views/Popover/                     Five tabs: NowPlaying, Queue, History, Cache, Settings
    Views/Floating/                    Aurora-haloed floating portrait
```

### API Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/speak` | Single-voice TTS — cache-checked first; opt-in `cacheable` controls whether a miss writes to cache |
| `POST` | `/speak/dialogue` | Multi-voice dialogue (no cache) |
| `GET` | `/queue` | Queue status |
| `POST` | `/queue/skip` | Skip current |
| `POST` | `/queue/pause` | Pause playback |
| `POST` | `/queue/resume` | Resume playback |
| `POST` | `/queue/seek` | Seek within track |
| `POST` | `/queue/clear` | Clear queue |
| `GET` | `/history` | Playback history |
| `POST` | `/history/replay` | Replay cached audio by history id |
| `GET` | `/cache/phrases` | List cached phrases with metadata; `?sort=recent\|popular`, `?limit=` |
| `DELETE` | `/cache/phrases/{key}` | Purge a single cached phrase by hash |
| `POST` | `/cache/clear` | Wipe every cached phrase (destructive) |
| `POST` | `/cache/play` | Replay cached phrase by hash key — free, never hits ElevenLabs |
| `GET` | `/voices` | Voice configuration |
| `GET` | `/settings` | API key (masked), voice ID, `expletives_enabled` |
| `POST` | `/settings` | Update API key (Keychain) / voice ID (validated) / `expletives_enabled` (persona mode) |
| `GET` | `/usage` | Current minute call count + daily char count + caps |
| `GET` | `/events` | SSE event stream |
| `GET` | `/health` | Health check |
| `GET` | `/` | Friendly help message (use the menu-bar app or `say.sh` CLI) |
| `GET` | `/portraits/{name}` | Caldwell portrait images served from `assets/portraits/` |

---

## License

MIT — same as upstream [tomc98/speak](https://github.com/tomc98/speak).
