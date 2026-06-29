# macOS Setup Guide

**Requires:** macOS 26 (Tahoe) or later, Apple Silicon. The app uses Liquid
Glass APIs and Swift 6.1+, both bundled with macOS 26 — no separate runtime to
install.

Pulsar is a SwiftUI menu-bar app. It serves the HTTP API on
`127.0.0.1:7865` — it **is** the daemon. There is no Python process.

## Install

### Option A — signed release (recommended)

1. Download the latest `Pulsar-*.dmg` from
   [GitHub releases](https://github.com/justinwilliames/pulsar-by-orbit/releases).
2. Mount it and drag `Pulsar.app` into `/Applications`.
3. The build is ad-hoc signed (not notarised), so strip the quarantine flag or
   Gatekeeper will block it:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Pulsar.app
   ```

### Option B — build from source

```bash
# Builds the Swift binary, assembles Pulsar.app, copies it to /Applications
scripts/install-caldwell-app.sh
```

### Auto-launch at login

```bash
scripts/install-caldwell-app-launchd.sh
```

Registers the `team.yourorbit.Pulsar` LaunchAgent (RunAtLoad +
KeepAlive) and retires any legacy daemon agent.

## Configure the ElevenLabs API key

1. Sign up at https://elevenlabs.io (free tier: 10,000 chars/month).
2. Create an API key at https://elevenlabs.io/app/settings/api-keys (starts
   with `sk_`).
3. Store it via the app's HTTP API:
   ```bash
   scripts/say.sh --set-api-key sk_...
   ```
   The key lives in the login Keychain (account `elevenlabs-api-key`) and
   survives reinstalls.

## Verify

```bash
# Health — the Swift app answers
curl http://127.0.0.1:7865/health
# → {"source":"swift","status":"ok","version":"swift-...","queue_size":0}

# Speak a test line
scripts/say.sh "Hello from Claude Code."

# Inspect settings (mode / muted / api_key_set) and ElevenLabs usage
scripts/say.sh --settings
scripts/say.sh --usage

# Open the popover dashboard from the menu-bar icon
```

## CLI Usage

```bash
# Basic speak
scripts/say.sh "Your message here"
scripts/say.sh "Deep voice" --voice Adam

# Queue controls
scripts/say.sh --status
scripts/say.sh --pause
scripts/say.sh --resume
scripts/say.sh --skip
scripts/say.sh --clear

# History
scripts/say.sh --history --limit 10

# Mode + mute
scripts/say.sh --polite   # expletives off
scripts/say.sh --potty    # expletives on
scripts/say.sh --mute
scripts/say.sh --unmute
```

## Troubleshooting

### Daemon not reachable on 7865
The Pulsar app isn't running. Launch it and check the LaunchAgent:
```bash
open -a Pulsar
launchctl list | grep CaldwellDashboard
```

### `HTTP 401: Unauthorized`
Invalid or missing API key. Re-set it and verify the key directly:
```bash
scripts/say.sh --set-api-key sk_...
curl -H "xi-api-key: sk_..." https://api.elevenlabs.io/v1/voices
# Should return a JSON voice list, not {"detail":{"status":"invalid_api_key"}}
```

### App won't launch / Gatekeeper blocks it
The build is ad-hoc signed. Strip quarantine:
```bash
xattr -dr com.apple.quarantine /Applications/Pulsar.app
```

## Available Voices

| Voice | Style |
|-------|-------|
| Claude | Cool, precise feminine AI |
| Rachel | Calm, clear, professional female |
| Adam | Deep, warm, authoritative male |
| Antoni | Friendly, conversational male |
| Josh | Deep, resonant, confident male |
| Bella | Soft, warm, approachable female |
| Charlotte | Warm, slightly accented female |
| Elli | Young, energetic female |
| Dorothy | Clear, pleasant, steady female |

See `voices.json` for full configuration.

## Next Steps

- **Dashboard:** the menu-bar popover — real-time queue with animated portraits.
- **Multi-voice dialogue & API reference:** see `README.md`.
