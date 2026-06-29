# Pulsar

<p align="center">
  <img src="assets/portraits/caldwell.png" width="180" alt="Pulsar" />
</p>

[![Build Pulsar](https://github.com/justinwilliames/pulsar-by-orbit/actions/workflows/package-dmg.yml/badge.svg)](https://github.com/justinwilliames/pulsar-by-orbit/actions/workflows/package-dmg.yml)

**Pulsar is a voice companion that lives in your menu bar and tells you — out loud — the moment your code is done, so you stop babysitting the screen.** A macOS menu-bar companion for Claude Code: out of the box it speaks with a free, fully-local Mac voice — no account, no API key, no per-word cost, and nothing leaving your machine. Add an [ElevenLabs](https://elevenlabs.io) key for a premium cloud voice, and Pulsar falls back to the local voice automatically when its credits run out.

It has a set of signature lines — *"Pushed, Sir."*, *"All green, Sir."*, *"Sorted, Sir."* — **[Pulsar's canon](CANON.md)**, which play free at the end of a turn.

Forked from [speak](https://github.com/tomc98/speak) by Thomas Csere.

**[→ Download the latest release](https://github.com/justinwilliames/pulsar-by-orbit/releases/latest)**

---

## Requirements

- macOS 26 (Tahoe) or later
- Optional: an [ElevenLabs](https://elevenlabs.io) account and API key for the premium cloud voice — out of the box Pulsar speaks with a free, local macOS voice (Daniel), no account or key required
- [Claude Code](https://claude.ai/code) with this skill installed

---

## Install

### 1. Download

Go to [Releases](https://github.com/justinwilliames/pulsar-by-orbit/releases/latest) and download `Pulsar-*.dmg`.

### 2. Drag to Applications

Open the `.dmg` and drag **Pulsar** into the **Applications** shortcut.

### 3. Remove Gatekeeper quarantine (required)

Pulsar is unsigned (no Apple Developer ID), so macOS will refuse to open it unless you run this once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Pulsar.app"
```

Then launch from Applications. The menu-bar icon appears.

### 4. Configure your API key and voice

Click the menu-bar icon → **Settings** tab:

- **ElevenLabs API key** — get yours at [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys). Stored in macOS Keychain.
- **Default Voice ID** — add a voice from the [Voice Library](https://elevenlabs.io/app/voice-library) to your VoiceLab, then paste its 20-character ID.

Hit **Save & validate** — Pulsar confirms the key and voice against ElevenLabs before saving.

### 5. Install as a Claude Code skill

```bash
mkdir -p ~/.claude/skills
ln -s ~/code/caldwell-speak ~/.claude/skills/caldwell-speak
```

Or clone the repo first if you haven't:

```bash
git clone https://github.com/justinwilliames/pulsar-by-orbit.git ~/code/caldwell-speak
mkdir -p ~/.claude/skills
ln -s ~/code/caldwell-speak ~/.claude/skills/caldwell-speak
```

Then **restart Claude Code** so it discovers the skill. The shipped [`SKILL.md`](SKILL.md) tells Claude to fire Pulsar at the end of every turn.

### 6. Install the hooks

```bash
~/code/caldwell-speak/scripts/install-hooks.sh
```

This wires two hooks into your `~/.claude/settings.json` (idempotent — it only adds them if absent and leaves your other hooks alone):

- **`SessionStart` → `session-start-voice.sh`** — when the app is running, injects a directive so Claude composes a fresh, *bespoke* line each turn. This is model-side: it rides your own Claude Code session, so there's no extra API key. When the app is off, it injects nothing and the voice stays dormant.
- **`Stop` → `stop-hook.sh`** — plays a cached canonical line as the fallback for any turn Claude doesn't speak on (debounced, so you never get double voice).

**Start a new Claude Code session** after running it. From then on Pulsar composes a custom line each turn, with cached canon as the floor.

---

## What you get

- **Speaks at every Claude Code turn-end** — completion ping so you know it's done without watching the screen.
- **Phrase cache** — repeated canonical phrases (e.g. "Pushed, Sir." / "Tests passing.") are cached locally as MP3s and replay for zero ElevenLabs credits. The free tier goes a long way.
- **Menu-bar popover** — History, Cache, and Settings tabs. See what was said, replay cached phrases, manage your API key and voice.
- **Floating portrait** — an animated portrait appears in the top-left corner when Pulsar is speaking. Draggable, stays across all Spaces, hides when the queue empties.
- **Mute toggle** — one click in the popover header. Menu-bar icon changes so you know you're muted.
- **Spend caps** — per-minute rate limit and daily character cap refuse calls before hitting ElevenLabs. Configurable; defaults are conservative.
- **Automatic updates** via Sparkle — Pulsar checks for new releases and prompts you when one is available.

---

## Updates

Pulsar uses [Sparkle](https://sparkle-project.org) for automatic updates. When a new release is available, Pulsar will prompt you to install it.

If you need to remove the quarantine flag after an update, run the same command as above:

```bash
xattr -dr com.apple.quarantine "/Applications/Pulsar.app"
```

---

## Credit usage

ElevenLabs charges per character. Three things keep it manageable on the free tier:

1. **Phrase cache** — generic reusable lines are cached on first use and replay free forever after. The skill flags cacheable lines automatically.
2. **Spend caps** — the daily char cap (default 2,000) refuses new API calls before they happen. Cache hits bypass the cap entirely.
3. **Mute** — one click in the popover stops all ElevenLabs calls until you unmute.

The Settings tab shows your live ElevenLabs monthly usage and a run-rate indicator so you can see if you're on pace.

---

## SKILL.md

The [`SKILL.md`](SKILL.md) file is the contract between Pulsar and Claude Code. It tells Claude:

- To fire `say.sh` at the end of every turn
- Which tier of line to compose (routine ping / substantive / detailed)
- When to stay silent (mute active, spend cap rejected, exact repetition)
- How to flag reusable lines for the phrase cache

If you want Pulsar quieter, edit the suppression list in `SKILL.md`.

---

## License

MIT — same as upstream [tomc98/speak](https://github.com/tomc98/speak).
