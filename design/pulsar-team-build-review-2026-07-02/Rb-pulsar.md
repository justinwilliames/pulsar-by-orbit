# Rb — Pulsar (Chief of Staff) — meta build review

Branch `pulsar-fixes` @ `346c221`, base `18b81a4`. 4 commits, +1018/−150 across 24 files. Tree clean, cache/ gitignored.

## 1. Regression surface — the untested interactions

**A. [HIGH] Deferred-removal flush depends solely on queue-drain; the sweeper is a 10-min backstop.**
`flushDeferredRemovals()` fires only when the worker drains the queue. If a drone's Stop arrives mid-speech (→ `pendingRemoval`) and then a *steady trickle* of same-category lines keeps the queue non-empty, the drone lingers until the 600s sweep — but only if `lastSeen` also ages out. Since `touchInFlightDrone` is now id-scoped (start only) and speech no longer refreshes, the pending drone *does* age out correctly. The real hole: **flush and sweep can both evict the same id in overlapping ticks and both broadcast** — no single-lens reviewer traces the flush-path (worker actor) against the sweep-path (detached 1Hz task) touching the same `inFlight`/`pendingRemoval` state. Actor serialisation prevents a data race, but produces redundant/duplicate broadcasts and a possible fade-in-then-out flicker.

**B. [HIGH] Persistence × restart × sweeper: restored `lastSeen` is honoured, but restored `pendingRemoval` is NOT.** `pendingRemoval` is in-memory only — it is never persisted. A drone that was deferred (Stop received, still speaking) at the moment of a daemon reload comes back from `drones.json` as a *live* drone with no pending flag. Its Stop already fired and will never fire again, so it now relies entirely on the 600s sweep to disappear. On restart, a just-stopped-but-lingering drone gets a fresh 10-min lease. Ghost-adjacent, by design gap.

**C. [MED] Promotion × restore: a restored generic (`atlas`/`unknown`) can be promoted to a category whose real owner also restored.** `promoteInFlightDrone` early-returns if any drone of the category exists, but across a restart two sessions' drones coexist in one store — a promotion can mis-attribute a surviving generic to a category that belongs to a *different* session's speaker.

## 2. Test coverage — none.
No `Tests/` dir, no `testTarget` in `Package.swift`, zero `XCTest`/`@Test`/`func test`. Every fix this session shipped unguarded.

**The one test to add:** an `AudioQueueActor` unit suite exercising the **inFlight lifecycle** — `addInFlightDrone → removeInFlightDrone (while isDroneSpeaking) → flushDeferredRemovals` and `sweepStaleDrones` with an injected `now`. `sweepStaleDrones(now:)` and `restoreInFlight` are already test-shaped (pure, injectable clock, file-backed). One suite guards A, B, C and the persistence round-trip — the highest-leverage guard on the whole branch.

## 3. Merge readiness — committable, with named gaps.
- Tree clean; no uncommitted/untracked files.
- Removed helpers (`homeOrbitOffset`, `stableArcIndex`) are fully gone — zero dangling refs.
- No `print(`/`FIXME`/`TODO`/`dump(` added. The 5 `NSLog` additions are intentional daemon logging (emoji-tagged, keep).
- `cache/drones.json` correctly gitignored — no persistence artefact will be committed.
- Design review dirs (`pulsar-team-2026-07-01/*`) are committed alongside code — cosmetic, harmless.

**Verdict: coherent and committable.** It is NOT the loose ends that block merge — it's the unguarded behavioural gaps (A/B). Ship-with-eyes-open, not ship-blind.

## 4. What's NOT been said — the unchallenged assumption.
**Every fix assumes `agent_id` is a stable, per-sub-agent, globally-unique key.** Both hooks fall back `agent_id → agentId → session_id`. If Claude Code doesn't populate `agent_id` (older/newer harness, or a hook payload shape change), *every* sub-agent in a session collapses onto the one `session_id` — so `addInFlightDrone` overwrites, `removeInFlightDrone` clears the whole session's presence on the first Stop, and persistence stores one drone where there were five. The entire drone-identity model — persistence, linger, promotion, sweep — rests on this one field being present and unique. It has not been verified against a live payload; it is assumed. If wrong, B, C and the linger logic all unravel at once.

## 5. Operational footguns.
- **[HIGH] `session_id` fallback is cross-session-unsafe.** On the fallback path, sub-agents from *different concurrent sessions* sharing a `session_id` scheme collide in one global `inFlight`. On a machine running two Claude Code sessions, one session's Stop can fade the other's drone. Fine on the happy path (`agent_id` present); a footgun the moment it isn't.
- **[MED] `drones.json` cross-machine / stale-store.** Persistence is repo-cache-relative (`cache/drones.json`), not per-host. A synced repo (iCloud/Dropbox) or a store written by a crashed daemon leaves a stale swarm that only the 600s sweep clears on next boot. Acceptable, but the store should arguably carry a daemon-PID/boot-id stamp so a foreign store is ignored rather than replayed.
- **[LOW] Hooks edit `~/.claude/settings.json` additively** with a timestamped backup and idempotent `ensure()` — clean. Fresh-install safe. `uninstall-hooks.sh` added this session (good hygiene).

## Top risks (for orchestrator)
- `[HIGH] identity — agent_id assumed unique, session_id fallback collides cross-session — verify live payload; drop the session_id fallback (owner: hooks)`
- `[HIGH] persistence — pendingRemoval not persisted, restored drone gets fresh 10-min lease — persist pendingRemoval or re-derive on restore (owner: AudioQueueActor)`
- `[HIGH] tests — zero automated coverage on daemon/persistence/linger — add inFlight-lifecycle XCTest suite (owner: build)`
- `[MED] broadcast — flush vs 1Hz sweep can double-evict/double-broadcast same id — dedupe broadcasts or single-source eviction (owner: AudioQueueActor/HTTPServer)`
- `[MED] promotion — cross-session generic promoted to wrong category after restore — scope promotion to same session (owner: AudioQueueActor)`

**Single most valuable test:** `AudioQueueActor` inFlight-lifecycle suite (add → deferred-remove-while-speaking → flush; + `sweepStaleDrones(now:)` with injected clock; + `restoreInFlight` round-trip). Guards A, B, C at once.

**Merge verdict:** COMMITTABLE, MERGE-WITH-CONDITIONS. No loose ends or dead code block it. Before merge, do the one cheap thing that de-risks the most: verify `agent_id` is present+unique in a live SubagentStart payload and drop the `session_id` fallback. That single check validates the assumption the whole branch stands on. The test suite is the follow-up, not a merge blocker.
