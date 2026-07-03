<div align="center">

<img src="assets/readme/pulsar-header.png" alt="Pulsar — it tells you the moment your code is done" width="640" />

<p align="center">
  <a href="https://github.com/justinwilliames/pulsar-by-orbit/actions/workflows/package-dmg.yml"><img src="https://github.com/justinwilliames/pulsar-by-orbit/actions/workflows/package-dmg.yml/badge.svg" alt="Build Pulsar" /></a>
  <a href="https://github.com/justinwilliames/pulsar-by-orbit/releases/latest"><img src="https://img.shields.io/github/v/release/justinwilliames/pulsar-by-orbit?include_prereleases&label=latest&color=6366F1" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/license-MIT-6366F1" alt="License MIT" />
  <img src="https://img.shields.io/badge/macOS-26%2B-6366F1" alt="macOS 26+" />
</p>

</div>

**Pulsar is a voice companion that lives in your menu bar and tells you — out loud — the moment your code is done, so you stop babysitting the screen.** It's a macOS menu-bar app for Claude Code. It speaks with a free, fully-local Mac voice: no account, no API key, no per-word cost, and nothing leaving your machine. Every line is synthesised by the built-in macOS `say` engine and played back on the spot.

It has a set of signature lines — *"Pushed."*, *"All green."*, *"Sorted."* — **[Pulsar's canon](CANON.md)**, the fallback floor for any turn Claude doesn't compose its own line on.

**[→ Download the latest release](https://github.com/justinwilliames/pulsar-by-orbit/releases/latest)**

---

## Requirements

- macOS 26 (Tahoe) or later, on Apple Silicon
- [Claude Code](https://claude.ai/code) — Pulsar installs its skill + hooks into it for you (one click, step 4)

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

The swarm is wired through Claude Code's `SubagentStart` and `SubagentStop` hooks (installed for you in step 4). A background sweep clears out any drone whose stop signal never arrived, and the current set survives a restart — so what's on screen matches what's actually running.

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

### 4. Connect it to Claude Code (one click — no repo, no Terminal)

Click the **Pulsar** menu-bar icon, open the **Settings** tab, and hit **Set up Pulsar in Claude Code**.

That's the whole step. The app installs its skill and every hook straight from its own bundle into `~/.claude/` — it backs up your `settings.json` first, adds only what's missing, and leaves any other hooks you have untouched. Then **restart Claude Code** so it picks everything up. From then on Pulsar composes a custom line each turn, with the cached canon as the floor.

What the one-click installer wires up:

- **`SessionStart` → `session-start-voice.sh`** — when the app is running, injects a directive so Claude composes a fresh, *bespoke* line each turn. This rides your own Claude Code session, so there's no extra key. When the app is off, it injects nothing and the voice stays dormant.
- **`Stop` → `stop-hook.sh`** — plays a cached canonical line as the fallback for any turn Claude doesn't speak on (debounced, so you never get double voice).
- **`Stop` → `chime.sh`** — a short turn-end sound.
- **`UserPromptSubmit` → `turn-start.sh`** — marks the start of a turn.
- **`SubagentStart` → `subagent-start.sh`** and **`SubagentStop` → `subagent-stop.sh`** — register and retire the sub-agent drones described above.
- **`statusLine` → `statusline.sh`** — the Claude Code status line.

<details>
<summary><b>Prefer to install from source?</b> (optional — for contributors)</summary>

If you're building from source or want the scripts in a repo you control, wire it up manually instead of using the in-app button:

```bash
git clone https://github.com/justinwilliames/pulsar-by-orbit.git ~/code/pulsar
mkdir -p ~/.claude/skills
ln -s ~/code/pulsar ~/.claude/skills/pulsar
~/code/pulsar/scripts/install-hooks.sh
```

`install-hooks.sh` is idempotent and does the same wiring as the in-app installer — it only adds hooks that are absent and leaves your others alone. Restart Claude Code afterward.

</details>

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

## Credits

Pulsar grew out of [speak](https://github.com/tomc98/speak) by Thomas Csere — MIT-licensed, and the foundation the voice engine is built on.

## License

MIT — see [LICENSE](LICENSE).

## Star History

<a href="https://www.star-history.com/?repos=justinwilliames%2Fcomet-by-orbit%2Cjustinwilliames%2Fpulsar-by-orbit%2Cjustinwilliames%2Forbit-for-claude%2Cjustinwilliames%2Forion-by-orbit&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=justinwilliames/comet-by-orbit%2Cjustinwilliames/pulsar-by-orbit%2Cjustinwilliames/orbit-for-claude%2Cjustinwilliames/orion-by-orbit&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=justinwilliames/comet-by-orbit%2Cjustinwilliames/pulsar-by-orbit%2Cjustinwilliames/orbit-for-claude%2Cjustinwilliames/orion-by-orbit&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=justinwilliames/comet-by-orbit%2Cjustinwilliames/pulsar-by-orbit%2Cjustinwilliames/orbit-for-claude%2Cjustinwilliames/orion-by-orbit&type=date&legend=top-left" />
 </picture>
</a>
