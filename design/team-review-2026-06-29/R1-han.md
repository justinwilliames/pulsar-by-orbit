# R1 — Han Müller (Staff Backend / Data Engineer)

**Verdict:** The spend gate is steering with a blindfold on — it gates on a number it doesn't durably persist, never records which engine actually spoke, and ships every bespoke line to a third party while a free, local, private voice path already sits in the codebase unused. The memory is a junk drawer; tidy it before you add a toggle.

---

## Top 3 findings

### 1. State/config integrity — the budget gate's "memory" is process-local and dies at every launch
`UsageTracker` (Engine/UsageTracker.swift) holds `sessionChars`, `baselineRemote`, `seededReset`, `seededLimit` entirely in RAM behind an `NSLock`. Nothing is persisted. Consequences the data will bite you on:

- **Every app restart resets `sessionChars` to 0 and re-baselines off whatever the laggy remote happens to say.** The `say.sh` daemon is install-launchd'd and the menubar app restarts often. So the local floor — the whole reason this class exists — is amnesiac across the exact event that happens most. The reconciliation story in the header comment ("we know exactly how many characters every fetch cost") is true only within one process lifetime.
- **`snapshot()` returns nil until BOTH a baseline and a limit are seen**, and the gate fails *open* on nil (`shouldSpeakBespoke` → `true`). So for the first N seconds of every launch — before `primeUsageBaseline()` completes its network round-trip — the budget gate is disabled and every line spends freely. That's a silent "spend hole" at exactly the moment a fresh session fires its loudest burst of turn-end pings.
- **`config.json` is read/written as `[String: String]`** (CaldwellConfig.set). One malformed hand-edit (a bare `true`, a nested object) and the whole `JSONSerialization ... as? [String:String]` cast fails → `reload()` silently returns → config silently reverts to defaults: **unmuted, expletives ON, default voice.** A mute that silently un-mutes itself is a data-integrity failure with a blast radius (Sir's screen-share, a meeting). No schema, no validation, no versioning on the one file that governs whether the thing talks.

### 2. Spend-tracking + budget-gate honesty — the gate is probabilistic and unauditable
`shouldSpeakBespoke()` computes a `health` ratio and then does `Double.random(in: 0..<1) < prob`. Two honesty problems:

- **It's a coin-flip with no ledger.** When a line gets downgraded to canon, the only trace is `reason: "budget-canon"` on the HTTP response — which `say.sh` throws into `/dev/null`. There is no counter of "bespoke spent vs bespoke throttled," no record of the `health` value at decision time. You cannot answer "did the gate fire correctly this month?" because nothing recorded that it fired. **Telemetry that records the action but not the outcome.**
- **`cycleLength` is hardcoded to 30 days** while the real reset is `next_character_count_reset_unix` from ElevenLabs. On a free tier the window is calendar-monthly; 30d vs 31d drift means the "even-burn line" is systematically wrong near month boundaries. Minor in magnitude, but it's a fabricated constant standing in for a value you already fetch.

### 3. Privacy / data-sovereignty — every bespoke line leaves the machine, and the local path already exists
This is the sharpest one. `ElevenLabsClient.fetchTTS` POSTs the raw `text` to `api.elevenlabs.io` for **every cache miss** — and those lines, by design (Tier 2/3 in the skill), *describe what Sir is building*: commit messages, findings, file names, "Build's fucked." That's a third-party egress of work-in-progress context, billed per character, logged on their side. Meanwhile `AudioQueueActor.speakNative` (line 339) **already** drives `/usr/bin/say -v Daniel` as a zero-cost, zero-network fallback — it's wired in, mute-aware, skip-interruptible. The local voice path is built; it is simply demoted to a failure handler instead of being a first-class, selectable engine. The proposed engine toggle isn't new plumbing — it's promoting code you already trust on the failure path to the happy path.

---

## The one thing I'd ship now
**Persist `UsageTracker` to a small JSON sidecar (`cache/usage-state.json`) and add an append-only spend ledger.** One file, atomic write on every `recordCharacters` / `reconcile`, holding `{seededReset, baselineRemote, sessionChars, seededLimit}` plus a rolling per-decision log line `{ts, engine, chars, cached|bespoke|budget-canon, health}`. This fixes the launch-amnesia spend hole, makes the gate auditable after the fact, and gives `/usage` a real `engine_breakdown` field. Everything else in this review — the toggle, the sovereignty win — depends on being able to *measure* which engine spoke and what it cost. You can't manage what you don't record.

## What I'd defer (not my call)
The UX of the two toggles (engine: ElevenLabs↔Mac; style: cached↔bespoke), the menubar surfacing, and whether Daniel Enhanced is *good enough* a voice to be the default. That's Yuki/Marcus/Aja territory — I only care that whichever engine speaks gets logged with its cost and its boundary-crossing.

## One question for another persona
**For Yuki/Priya:** when the budget gate downgrades a bespoke line to canon, should Sir *know* it happened — a subtle menubar state, a distinct chime — or is silent degradation the correct behaviour? The data side can surface it either way; the call is whether a quietly-cheaper Caldwell is a feature or a lie.

— Han
