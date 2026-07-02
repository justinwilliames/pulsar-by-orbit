# macOS Setup Guide

**Requires:** macOS 26 (Tahoe) or later, Apple Silicon. The app uses Liquid
Glass APIs and Swift 6.1+, both bundled with macOS 26 — no separate runtime to
install.

Pulsar is a SwiftUI menu-bar app. It serves the HTTP API on
`127.0.0.1:7865` — it **is** the server. There is no Python process.

The voice runs entirely on macOS's built-in `say` engine: lines are
synthesised locally and played back with `afplay`. Nothing crosses the network,
there's no account, and there's no key to configure.

## Install

### Option A — release build (recommended)

1. Download the latest `Pulsar-*.dmg` from
   [GitHub releases](https://github.com/justinwilliames/pulsar-by-orbit/releases).
2. Mount it and drag `Pulsar.app` into `/Applications`.
3. The build is unsigned (no Apple Developer ID), so strip the quarantine flag
   or Gatekeeper will block it:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Pulsar.app
   ```

### Option B — build from source

```bash
# Builds the Swift binary, assembles Pulsar.app, copies it to /Applications
scripts/install-pulsar-app.sh
```

### Auto-launch at login

```bash
scripts/install-pulsar-app-launchd.sh
```

Registers the `team.yourorbit.Pulsar` LaunchAgent (RunAtLoad +
KeepAlive) and retires any legacy daemon agent.

## Verify

```bash
# Health — the Swift app answers
curl http://127.0.0.1:7865/health
# → {"source":"swift","status":"ok","version":"swift-...","queue_size":0}

# Speak a test line
scripts/say.sh "Hello from Claude Code."

# Inspect settings (persona mode / muted)
scripts/say.sh --settings

# Open the popover dashboard from the menu-bar icon
```

## CLI Usage

```bash
# Basic speak
scripts/say.sh "Your message here"

# Tag a line to a sub-agent drone's voice (see the roster below)
scripts/say.sh "Search complete." --agent voyager

# Queue controls
scripts/say.sh --status
scripts/say.sh --pause
scripts/say.sh --resume
scripts/say.sh --skip
scripts/say.sh --clear

# History
scripts/say.sh --history --limit 10

# Persona + mute
scripts/say.sh --polite   # expletives off (default)
scripts/say.sh --potty    # expletives on
scripts/say.sh --mute
scripts/say.sh --unmute
```

## Troubleshooting

### Not reachable on 7865
The Pulsar app isn't running. Launch it and check the LaunchAgent:
```bash
open -a Pulsar
launchctl list | grep Pulsar
```

### App won't launch / Gatekeeper blocks it
The build is unsigned. Strip the quarantine flag:
```bash
xattr -dr com.apple.quarantine /Applications/Pulsar.app
```

### No sound
Check the popover isn't muted (the menu-bar icon shows mute state), and confirm
the queue is moving with `scripts/say.sh --status`. The voice uses `afplay`, so
system output volume and the selected output device apply as normal.

## The voice roster

Every line is spoken in a character voice — you don't pick one. Pulsar speaks as
itself; when Claude Code spawns a sub-agent, that drone speaks in its own voice.
All seven are standard macOS system voices, so they're already installed:

| Character | Role | Voice |
|-----------|------|-------|
| Pulsar | Host / orchestrator | Daniel (en-GB) |
| Voyager | Explorer | Fred (en-US) |
| Sentinel | Reviewer | Karen (en-AU) |
| Nova | Builder | Samantha (en-US) |
| Nebula | Artist | Moira (en-IE) |
| Echo | Writer | Tessa (en-ZA) |
| Atlas | Generalist | Rishi (en-IN) |

If a system voice isn't present, macOS resolves it to the closest installed
variant. To add more, open **System Settings → Accessibility → Spoken Content →
System Voice → Manage Voices**.

## Next Steps

- **The drone swarm:** the marquee feature — see `README.md` for how sub-agents
  render as orbiting companion drones.
- **Dashboard:** the menu-bar popover — real-time queue with the animated
  portrait.
