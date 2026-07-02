# Voyager — State-model / data-integrity / lifecycle review

Target: `pulsar-fixes` @ 346c221. Files: `AudioQueueActor.swift`, `CaldwellHTTPServer.swift`.
Live daemon probed (no mute/restart touched); all test drones cleaned up.

## Verdict
The core lifecycle is **sound** — promotion persists correctly, deferred removal has real backstops, idempotency mostly holds. But there are **two genuine data-integrity bugs** (concurrent writers; double-start clobber) and **two lifecycle sharp-edges** (restore-ghost linger window; promotion racing a live sibling) worth fixing before ship.

---

## Q1 — Persistence + promotion — CORRECT (verified live)
`promoteInFlightDrone` mutates via `inFlight[id]?.category = trimmed`, which trips the `didSet` → `persistInFlight()`. Verified live: registered `vtest-1` as `atlas`, fired `/speak --agent echo` (category absent from set), disk immediately showed the winning generic flipped to `echo`. On restore it comes back **promoted (`echo`)**, not `atlas`. No bug.

Sub-note: when the promoted category **already exists** in the swarm, promote short-circuits at the "already labelled" guard and returns false — the generic stays `atlas`. Correct (avoids dupes), but means a second same-category sibling never reveals its true face. Cosmetic, not a correctness hole.

## Q2 — Restore + reconciliation — MOSTLY OK, one sharp edge
Restore preserves real `lastSeen`, so a drone aged past 600s self-heals on the **first 1s sweep tick** — good. **Gap:** a sub-agent that finished 30s before shutdown (Stop hit a dead daemon) is restored and then lingers a full `600 − age` seconds as a visible ghost. Not a leak (it sweeps), but the window is user-visible. A restored ghost **cannot be wrongly promoted or claimed**: promote only ever targets `atlas`/`unknown`, and a restored real-category drone is skipped. A restored *atlas* ghost, however, is a **valid promotion target** — a new session's first `--agent X` line can retag a dead drone from a prior session as X (see Q3-race). Consider stamping restored drones with a shorter effective TTL, or reconciling against live PIDs, if the ghost window matters.

## Q3 — Linger lifecycle — BACKSTOP HOLDS, one leak-class edge
`pendingRemoval` defers stop while a same-category line plays/queues. If the main session narrates as `pulsar` forever, that does **not** hold a `voyager` drone (category-scoped match) — good. A busy *same-category* sibling streaming lines **can** hold the dead drone until either its category's queue drains (`flushDeferredRemovals` per-line) or the 600s sweep. Sweep clears `pendingRemoval` (line 457) so **no set leak**. 

**Re-registration edge:** if `/subagent/start` reuses an id currently in `pendingRemoval`, `addInFlightDrone` overwrites the entry but **`pendingRemoval` still contains that id**. The next `flushDeferredRemovals` will then remove the freshly-re-registered live drone the moment its category is quiet — a live drone silently vanishes. `addInFlightDrone` should `pendingRemoval.remove(id)`.

## Q4 — Data shape — ONE REAL BUG (concurrent writers)
Codable round-trip of epoch `Double` is fine — no TZ issue (absolute epoch), precision loss sub-microsecond, irrelevant. **Bug:** `persistInFlight` does a non-atomic `data.write(to:)` to a shared repo-cache path with **no file lock**. Two app instances (or the documented multi-session reality — I watched *other* sessions mutate `drones.json` mid-test) last-writer-wins the whole map, silently dropping the other instance's drones and corrupting-readable-but-wrong state. Even single-instance, a relaunch racing the old process's final write can read a torn file (mitigated only by the `try?` → empty set). Fix: atomic write (`.atomic`) at minimum; ideally a single-owner lock or per-session keyspace.

## Q5 — Idempotency
- **Double `/subagent/start` same id, different category → CLOBBER (verified):** started `sentinel`, re-started `nova` → entry became `nova` + `lastSeen` reset. A retried/duplicated Start hook silently rewrites a drone's identity and resets its staleness clock. Low-severity but real; `addInFlightDrone` should no-op or preserve category on an existing id unless intentionally re-tagging.
- **Stop unknown id → clean no-op (verified):** returns `ok:true`, clears any stray `pendingRemoval`. Correct.
- **Promote when id already left:** promote scans the live map only; a departed id is simply absent. Safe.

---

## Top bugs (severity-ordered)
- `[MED] AudioQueueActor.swift:283-292 persistInFlight` — non-atomic, unlocked write to shared `drones.json`; concurrent app instances / session writers last-writer-wins and drop drones (observed live). Fix: `data.write(to: url, options: .atomic)` + single-owner lock or per-session keyspace.
- `[MED] AudioQueueActor.swift:326 addInFlightDrone` — re-registering an id that's in `pendingRemoval` leaves it pending → `flushDeferredRemovals` later evicts the *live* re-registered drone. Fix: `pendingRemoval.remove(id)` in `addInFlightDrone`.
- `[LOW] AudioQueueActor.swift:326-328 addInFlightDrone` — double Start clobbers category + resets `lastSeen` (verified sentinel→nova). Fix: no-op/preserve on existing id.
- `[LOW] restoreInFlight (AudioQueueActor.swift:300)` — a sub-agent that Stopped during downtime is restored and lingers up to `600 − age`s as a visible ghost, and if it was `atlas` it's a promotion target for a new session. Fix: shorter restored TTL or live-PID reconcile.
