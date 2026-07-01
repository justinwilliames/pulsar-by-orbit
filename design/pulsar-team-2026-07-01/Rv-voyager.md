# Voyager — State-Model / Lifecycle Verification (pulsar-fixes @ HEAD)

Scope: AudioQueueActor, CaldwellHTTPServer, DroneRegistry, subagent-start.sh.
Method: traced the state machine + live-daemon smoke test on 127.0.0.1:7865.

## Verdict per behaviour

**1. Full lifecycle (general-purpose → atlas → promote → Stop) — PASS.**
Hook maps `general-purpose`→`atlas`; `/subagent/start` registers presence.
A tagged `--agent voyager` line calls `promoteInFlightDrone` which flips ONE
generic (`atlas`/`unknown`) to `voyager` and re-broadcasts. SubagentStop
removes the id. Live test: 4 test drones registered, one promoted
(unknown→echo), all removed on stop — no ghost, no orphan.

**2. `unknown` end-to-end — PASS.** Hook emits `unknown` (atlas reserved).
Daemon accepts it (`rawCategory == "unknown" || isDrone(...)`). Registry has a
coherent neutral `unknown` drone (grey, Daniel voice → Pulsar portrait
fallback). It IS in `DroneRegistry.categories`, so `stableArcIndex`
(`firstIndex(of:)`) gives it a real orbit lane and `participants` renders it —
consistent with FloatingHeadsView. Nothing coerces it back to atlas. Live
register of `unknown` rendered and promoted correctly.

**3. Promotion edges — PASS.**
(a) No generic left / category already present → `promoteInFlightDrone` early-
returns false, no dupe, no broadcast. Verified with `--agent atlas/voyager/
nova/sentinel` while present: zero dupes.
(b) 3 same-category announces → first promotes (if a generic exists), rest hit
the "already present" guard → sane, no dupes.
(c) Ghost still present for category X → the `contains(category==X)` guard sees
the ghost and returns false, so a live sibling is NOT separately promoted. Minor
cosmetic: a live worker can stay a generic behind a ghost until the ghost ages
out (≤10 min). Not a leak — self-heals. [NIT]

**4. TTL 600 + reliable stop — PASS.** With speech-refresh removed, `lastSeen`
moves only on spawn + id-scoped touch, so a silent long-runner is NOT swept by
loss of speech — only by absence of a Stop for 10 min. Given SubagentStop now
retries, 600s is a sound backstop: long enough to outlast any real spawn→Stop
gap, short enough to clear a genuinely-dropped ghost quickly. No legit agent at
risk.

**5. Live smoke — PASS.** Registered atlas/atlas/unknown; fired echo (promoted
newest generic), voyager/nova/sentinel (all no-op, present); no dupes; all 4
stopped cleanly. Bundled Resources hook copy is byte-identical to canonical.

## Flags
- [NIT] 3(c): live worker can shadow behind a ghost up to TTL. Cosmetic only.
- [NIT] `rawCategory == "unknown"` in the daemon guard is redundant now that
  `unknown` is a real drone (`isDrone` already true). Harmless — leave or drop.

No BLOCKER, no BUG. State model is coherent end-to-end.
