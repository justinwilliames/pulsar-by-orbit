# R2 — Engineering Cross-Reference (Sloan Park × Han Müller)

**Date:** 2026-06-29 · Round 2 · code re-verified against `Engine/*` and `HTTPServer/CaldwellHTTPServer.swift`.

---

## Where we AGREE

**Sloan:** The native `say` path is real, free, and wired — but it is *fallback-only* and *lies in the data*. `playEntry` (AudioQueueActor.swift:386–389) calls `speakNative` then records `recordHistory(... failed: true)` even when Daniel spoke the line perfectly, and computes no envelope so the portrait stays frozen. Verified line-for-line.

**Han:** Agreed, and the same path is the privacy and cost win — every cache-miss bespoke line POSTs raw work-in-progress text to ElevenLabs (ElevenLabsClient.swift:82–116). The toggle isn't new plumbing; it's promoting trusted failure-path code to the happy path. We both land on the *same single prerequisite*: **make `engine` a first-class field on `AudioEntry`, route `playEntry` on it, and record native success as `failed: false` with its own history `type`.** That one change is the floor for both toggles and the default-flip.

**Both:** The budget gate is half-obsolete the moment Mac-voice is selectable. Today it downgrades a bespoke line to a *cached canon ping* (a different sentence). The correct throttle is "speak the **actual bespoke line** through the **free local voice**." Gate and engine must be designed together or they fight.

---

## Where we FIGHT

**Sloan:** The true prerequisite is the **`engine`-field refactor**. Until `AudioEntry` carries intent and history stops mislabelling, every other fix is built on lying telemetry. Persistence is important but secondary — a process-local counter that's *honest* beats a persisted one feeding a gate nobody can observe.

**Han:** Respectfully no. The refactor makes the *engine* observable; it does nothing for the *spend ledger*. `UsageTracker` (UsageTracker.swift) is 100% RAM behind an `NSLock` — `sessionChars`, `baselineRemote`, `seededLimit` all reset every launch, and the daemon restarts constantly. The gate steers on `snapshot()`, which **returns nil until both baseline AND limit are seen** (line 61–68) and fails *open* (CaldwellHTTPServer.swift:810–811). So the prerequisite is **usage persistence** — without it the engine field just cleanly labels a gate that's blind for the first network round-trip of every session.

**Resolution:** They're orthogonal, not competing — but if forced to sequence, the **engine field ships first** (it unblocks both *toggles*, the visible deliverable) and **persistence ships immediately after** (it unblocks the *gate's correctness*, the invisible one). We are not pretending one obviates the other.

---

## The finding that needs BOTH lenses

**The cold-cache spend hole — an engineering control with a data blind spot.** At CaldwellHTTPServer.swift:1014–1019, when `shouldSpeakBespoke()` returns false the handler calls `playCanonFallback`; if **no canon is cached**, it falls through and *proceeds with the full bespoke spend anyway* (line 1018). 

**Han:** This is precisely the fresh-launch state. New session → `sessionChars=0`, baseline un-seeded → `snapshot()` nil → gate fails open → it *wants* to throttle but the canon cache may be cold → it spends freely. The single loudest burst of turn-end pings hits at exactly the moment the gate is both blind (no persisted state) and toothless (no canon to fall back to). 

**Sloan:** And it's *unobservable*. The only trace a throttle happened is `reason: "budget-canon"` on the HTTP response — which `say.sh` discards. There is no counter of bespoke-spent vs throttled, no record of `health` at decision time, no signal that the gate fell through to a spend. You cannot answer "did the gate work this month?" Neither lens catches this alone: Sloan sees an untestable `Double.random` gate (line 825, RNG not injected — confirmed), Han sees amnesiac state — but the *danger* is the intersection, a silent spend hole no telemetry records.

---

## Sharpened / retracted from R1

- **Sharpened (Sloan #1):** confirmed `failed: true` on successful native playback (line 389) AND no envelope on the native path (failed branch returns at 394 before envelope extraction at 399). Both true. The portrait-won't-move claim is real.
- **Sharpened (Han #2):** `cycleLength = 30 * 24 * 3600` is hardcoded (line 820) while the real reset `next_character_count_reset_unix` is already fetched and lives in `snap.reset`. The constant is fabricated where a real value sits one field away.
- **Stands (Han #1):** config `[String:String]` cast (CaldwellConfig.swift:127) silently returns on malformed JSON → reverts to defaults: **unmuted, expletives ON**. A mute that un-mutes itself. Confirmed, no schema/validation.
- **No retractions.** Every R1 claim survived code re-check.

---

## Minimal correct data/queue model (what we'd commit to)

1. **`AudioEntry.engine: VoiceEngine` (`.elevenlabs` / `.native`)** — set at enqueue from the resolved toggle; `playEntry` switches on it instead of inferring from `fetchFailed`. Native success records `failed: false`, `type: "native"`; compute envelope for the native path too (drive `say` to an `-o` AIFF, reuse `extractEnvelope`) so the portrait moves.
2. **`fetchFailed` keeps its real meaning** — an ElevenLabs error that *falls back* to native, distinct from a *chosen* native line. History/`/events` must tell these apart.
3. **Persisted `cache/usage-state.json`** — atomic write on every `recordCharacters`/`reconcile`/`seedIfNeeded`, holding `{seededReset, baselineRemote, sessionChars, seededLimit}`. Kills launch-amnesia and the fail-open hole. Re-baseline on `reset` change as today.
4. **Append-only spend ledger** (`{ts, engine, chars, decision: cached|bespoke|budget-canon|budget-fellthrough, health}`) — makes the gate auditable and powers an `engine_breakdown` on `/usage`. Note the new `budget-fellthrough` decision: the cold-cache spend must be recorded, not invisible.
5. **Inject the RNG** into `shouldSpeakBespoke` (seam param defaulting to `Double.random`) so the one most-expensive decision in the system gets a deterministic test.
6. **Startup voice probe** — `say -v "<voice>" -o /dev/null ""`, result on `/health` + `/settings`, so the game-changer voice has a health check before it's the default.

---

## One question for the design/story pair

**To Aja & Yuki (jointly):** Aja's R1 non-negotiable is "the operator never sees an engine toggle — one identity, engine invisible." The proposed feature #1 *is* a visible engine toggle. These are in direct conflict. **Do we ship an operator-facing engine toggle at all, or only an invisible per-line auto-route (free-by-default, ElevenLabs as silent premium)?** The data/queue model above supports *either* — the `engine` field and ledger are identical whether the choice is Sir's or the router's. But it changes what Settings exposes and whether `reason: "budget-canon"` ever surfaces to a human. We need that decision before we build the Settings surface, or we'll build the wrong one.

— Sloan & Han
