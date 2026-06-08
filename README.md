# Caldwell

<p align="center">
  <img src="assets/portraits/caldwell.png" width="180" alt="Caldwell" />
</p>

[![Build Caldwell](https://github.com/justinwilliames/caldwell-speak/actions/workflows/package-dmg.yml/badge.svg)](https://github.com/justinwilliames/caldwell-speak/actions/workflows/package-dmg.yml)

A macOS menu-bar app that gives Claude Code a voice. Alfred Pennyworth meets ElevenLabs — butler-formal RP, two registers (Polite or Potty Mouth), and a phrase cache that makes repeated lines free. Caldwell speaks at the end of every Claude Code turn so you know when it's done, without watching the screen.

A fork of [tomc98/speak](https://github.com/tomc98/speak) by Thomas Csere.

**[→ Download the latest release](https://github.com/justinwilliames/caldwell-speak/releases/latest)**

---

## Requirements

- macOS 14 (Sonoma) or later
- An [ElevenLabs](https://elevenlabs.io) account and API key
- [Claude Code](https://claude.ai/code) with this skill installed

---

## Install

### 1. Download

Go to [Releases](https://github.com/justinwilliames/caldwell-speak/releases/latest) and download `Caldwell-*.dmg`.

### 2. Drag to Applications

Open the `.dmg` and drag **Caldwell** into the **Applications** shortcut.

### 3. Remove Gatekeeper quarantine (required)

Caldwell is unsigned (no Apple Developer ID), so macOS will refuse to open it unless you run this once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Caldwell.app"
```

Then launch from Applications. The menu-bar icon appears.

### 4. Configure your API key and voice

Click the menu-bar icon → **Settings** tab:

- **ElevenLabs API key** — get yours at [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys). Stored in macOS Keychain.
- **Default Voice ID** — add a voice from the [Voice Library](https://elevenlabs.io/app/voice-library) to your VoiceLab, then paste its 20-character ID. Look for an older British male voice — RP or Estuary, capable of carrying both registers.

Hit **Save & validate** — Caldwell confirms the key and voice against ElevenLabs before saving.

### 5. Install as a Claude Code skill

```bash
mkdir -p ~/.claude/skills
ln -s ~/code/caldwell-speak ~/.claude/skills/caldwell-speak
```

Or clone the repo first if you haven't:

```bash
git clone https://github.com/justinwilliames/caldwell-speak.git ~/code/caldwell-speak
mkdir -p ~/.claude/skills
ln -s ~/code/caldwell-speak ~/.claude/skills/caldwell-speak
```

Then **restart Claude Code** so it discovers the skill. The shipped [`SKILL.md`](SKILL.md) tells Claude to fire Caldwell at the end of every turn.

---

## What you get

- **Speaks at every Claude Code turn-end** — completion ping so you know it's done without watching the screen.
- **Two registers** — toggle in the Settings tab:
  - **Polite** — butler-formal RP, no swearing. Same dry asides, same willingness to tell you an idea is bad. Just clean.
  - **Potty Mouth** (default) — RP precision with unflinching expletives where the moment earns them. The contrast does the comedy.
- **Phrase cache** — repeated canonical phrases (e.g. "Pushed, Sir." / "Tests passing.") are cached locally as MP3s and replay for zero ElevenLabs credits. The free tier goes a long way.
- **Menu-bar popover** — History, Cache, and Settings tabs. See what was said, replay cached phrases, manage your API key and voice.
- **Floating portrait** — an animated portrait appears in the top-left corner when Caldwell is speaking. Draggable, stays across all Spaces, hides when the queue empties.
- **Mute toggle** — one click in the popover header. Menu-bar icon changes so you know you're muted.
- **Spend caps** — per-minute rate limit and daily character cap refuse calls before hitting ElevenLabs. Configurable; defaults are conservative.
- **Automatic updates** via Sparkle — Caldwell checks for new releases and prompts you when one is available.

---

## Updates

Caldwell uses [Sparkle](https://sparkle-project.org) for automatic updates. When a new release is available, Caldwell will prompt you to install it.

If you need to remove the quarantine flag after an update, run the same command as above:

```bash
xattr -dr com.apple.quarantine "/Applications/Caldwell.app"
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

The [`SKILL.md`](SKILL.md) file is the contract between Caldwell-the-app and Claude Code. It tells Claude:

- To fire `say.sh` at the end of every turn
- Which tier of line to compose (routine ping / substantive / detailed)
- When to stay silent (mute active, spend cap rejected, exact repetition)
- How to flag reusable lines for the phrase cache

If you want Caldwell quieter, edit the suppression list in `SKILL.md`. If you want to disable swearing without losing the persona, flip to Polite mode in the Settings tab.

---

## License

MIT — same as upstream [tomc98/speak](https://github.com/tomc98/speak).
