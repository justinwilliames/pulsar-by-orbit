# Pulsar

<p align="center">
  <img src="assets/readme/pulsar.png" width="200" alt="Pulsar" />
</p>

[![Build Pulsar](https://github.com/justinwilliames/pulsar-by-orbit/actions/workflows/package-dmg.yml/badge.svg)](https://github.com/justinwilliames/pulsar-by-orbit/actions/workflows/package-dmg.yml)

**Pulsar is a voice companion that lives in your menu bar and tells you — out loud — the moment your code is done, so you stop babysitting the screen.** It's a macOS menu-bar app for Claude Code. It speaks with a free, fully-local Mac voice: no account, no API key, no per-word cost, and nothing leaving your machine. Every line is synthesised by the built-in macOS `say` engine and played back on the spot.

It has a set of signature lines — *"Pushed."*, *"All green."*, *"Sorted."* — **[Pulsar's canon](CANON.md)**, the fallback floor for any turn Claude doesn't compose its own line on.

Forked from [speak](https://github.com/tomc98/speak) by Thomas Csere.

**[→ Download the latest release](https://github.com/justinwilliames/pulsar-by-orbit/releases/latest)**

---

## Requirements

- macOS 26 (Tahoe) or later, on Apple Silicon
- [Claude Code](https://claude.ai/code) with this skill installed

That's the whole list. The voice runs on macOS's built-in `say` — there's no account to create, no key to paste, and no service to reach over the network.

---

## Meet the swarm

<p align="center">
  <img src="assets/readme/drone-swarm.png" alt="Meet the swarm — Pulsar and the six drones" />
</p>

Claude Code spawns sub-agents to fan work out — one to search the codebase, another to review it, a third to build. Pulsar makes that visible. When a sub-agent starts, a companion **drone** appears and orbits the Pulsar portrait; when it finishes, the drone fades out. Whichever character is speaking swaps to centre stage and lip-syncs the line, its colour lighting the subtitle glow.

Seven characters, each with its own voice and role:

- **Pulsar** — the host and orchestrator. The one you hear most of the time.
- **Voyager** — explorer. Searching, reading, mapping the code.
- **Sentinel** — reviewer. QA, security, checking the work.
- **Nova** — builder. Writing and refactoring.
- **Nebula** — artist. Design and visual work.
- **Echo** — writer. Docs and copy.
- **Atlas** — the generalist, for everything that doesn't fit the others.

The swarm is wired through Claude Code's `SubagentStart` and `SubagentStop` hooks (installed in step 5). A background sweep clears out any drone whose stop signal never arrived, and the current set survives a restart — so what's on screen matches what's actually running.

---

## Install

### 1. Download

Go to [Releases](https://github.com/justinwilliames/pulsar-by-orbit/releases/latest) and download `Pulsar-*.dmg`.

### 2. Drag to Applications

Open the `.dmg` and drag **Pulsar** into the **Applications** shortcut.

### 3. Clear the Gatekeeper quarantine (required)

Pulsar is unsigned — there's no Apple Developer ID behind it — so macOS refuses to open it until you strip the quarantine flag. Run this once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Pulsar.app"
```

Then launch from Applications. The menu-bar icon appears.

### 4. Install as a Claude Code skill

```bash
mkdir -p ~/.claude/skills
ln -s ~/code/pulsar ~/.claude/skills/pulsar
```

If you haven't cloned the repo yet, do that first:

```bash
git clone https://github.com/justinwilliames/pulsar-by-orbit.git ~/code/pulsar
mkdir -p ~/.claude/skills
ln -s ~/code/pulsar ~/.claude/skills/pulsar
```

Then **restart Claude Code** so it discovers the skill. The shipped [`SKILL.md`](SKILL.md) tells Claude to fire Pulsar at the end of every turn.

### 5. Install the hooks

```bash
~/code/pulsar/scripts/install-hooks.sh
```

This is idempotent — it wires the hooks and statusline into your `~/.claude/settings.json` only if they're absent, and leaves your other hooks alone. It sets up:

- **`SessionStart` → `session-start-voice.sh`** — when the app is running, injects a directive so Claude composes a fresh, *bespoke* line each turn. This rides your own Claude Code session, so there's no extra key. When the app is off, it injects nothing and the voice stays dormant.
- **`Stop` → `stop-hook.sh`** — plays a cached canonical line as the fallback for any turn Claude doesn't speak on (debounced, so you never get double voice).
- **`Stop` → `chime.sh`** — a short turn-end sound.
- **`UserPromptSubmit` → `turn-start.sh`** — marks the start of a turn.
- **`SubagentStart` → `subagent-start.sh`** and **`SubagentStop` → `subagent-stop.sh`** — register and retire the sub-agent drones described above.
- **`statusLine` → `statusline.sh`** — the Claude Code status line.

**Start a new Claude Code session** after running it. From then on Pulsar composes a custom line each turn, with the cached canon as the floor.

---

## What you get

- **Speaks at every Claude Code turn-end** — a completion ping, so you know it's done without watching the screen.
- **The drone swarm** — sub-agents show up as orbiting companion drones and the speaker lip-syncs. See [Meet the swarm](#meet-the-swarm).
- **Menu-bar popover** — History, Cache, and Settings tabs. See what was said, replay cached lines, set the persona.
- **Floating portrait** — an animated portrait appears in the top-left corner while Pulsar is speaking. Draggable, stays across all Spaces, hides when the queue empties.
- **Mute toggle** — one click in the popover header. The menu-bar icon changes so you know you're muted.
- **Polite or Potty Mouth** — a persona toggle in Settings. Polite is the default; flip it if you want the sweary version.
- **Phrase cache** — repeated canonical lines are stored locally and replayed instantly. Since the voice is free, this is a latency nicety, not a cost saver — the cache just skips re-synthesising a line you've already heard.
- **Automatic updates** via Sparkle — Pulsar checks for new releases and prompts you when one's available.

---

## Updates

Pulsar uses [Sparkle](https://sparkle-project.org) for automatic updates. When a new release is available, Pulsar prompts you to install it.

If you need to clear the quarantine flag again after an update, run the same command as before:

```bash
xattr -dr com.apple.quarantine "/Applications/Pulsar.app"
```

---

## SKILL.md

The [`SKILL.md`](SKILL.md) file is the contract between Pulsar and Claude Code. It tells Claude:

- To fire `say.sh` at the end of every turn
- Which tier of line to compose (routine ping / substantive / detailed)
- How to tag a line to a drone voice with `--agent <category>`
- When to stay silent (mute active, exact repetition)

If you want Pulsar quieter, edit the suppression rules in `SKILL.md`.

---

## License

MIT — same as upstream [tomc98/speak](https://github.com/tomc98/speak).
