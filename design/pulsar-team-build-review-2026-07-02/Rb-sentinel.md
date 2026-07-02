# Sentinel — Engineering Bug Hunt (Rb)

Build: `pulsar-fixes` @ `346c221`. Scope: persistence + speaker-linger lifecycle
in `AudioQueueActor.swift` and `CaldwellHTTPServer.swift`.
Method: full read of both files + diff `6f3ea28..HEAD`, live daemon probes
(register/stop verified persistence writes; test drone `SENTINEL_TEST_1` registered
and cleaned up).

---

## Findings (severity-ordered)

### [HIGH] restore races the live listener — a burst of `/subagent/stop` at startup is silently lost
`AppDelegate.applicationDidFinishLaunching` calls `httpServer.start()` (line 53)
**then** `httpServer.configure()` inside a *separate, un-awaited* `Task` (lines 54-58).
`start()` brings the Hummingbird listener up on 7865 immediately; `configure()` →
`restoreInFlight()` runs concurrently. So there is a real window where the server
accepts requests **before** `inFlight` is repopulated from `drones.json`.

Consequence, and it's the exact orphan case the persistence feature exists to fix:
a `/subagent/stop` (or `/speak --agent`) that arrives in that window sees an **empty**
`inFlight`. `removeInFlightDrone` hits its `guard inFlight[id] != nil` → returns false,
no-op. Then `restoreInFlight()` runs a beat later and **resurrects** the very drone
that was just told to stop. The ghost then orbits until the 600s sweep. Persistence
turned a lost-stop into a *reappearing* stop.

Also: `restoreInFlight` broadcasts the restored set (server.swift:44-48), but if an
`/events` client connected in that pre-restore window it already got an empty
`drones_in_flight` in its initial replay (`handleEvents` line 392-400). It's corrected
by the broadcast only if the client is still attached — a reconnect that lands inside
the window renders an empty swarm until the next mutation.

Fix: `await audioQueue.restoreInFlight()` (and the initial broadcast) **before**
`start()`, or gate route handling until a `configured` flag flips. Restore is cheap and
must be a strict happens-before the listener.

### [MED] `persistInFlight()` is synchronous file I/O on the actor — write-amplification + torn-write corruption
`inFlight { didSet { persistInFlight() } }` (line 253-255) does a synchronous
`JSONEncoder().encode` + `FileManager.createDirectory` + `data.write(to:)` on the
**actor's** executor, on *every* mutation: each add, each stop, each promote, and —
critically — **once per stale id inside the sweep loop** (`sweepStaleDrones` mutates
`inFlight` per-key, line 456, so N stale drones = N full-file rewrites in one tick) and
per flushed id in `flushDeferredRemovals`. Under a live multi-agent roll-call the actor
serialises every `/speak`, `/queue`, `markReady`, etc. behind these blocking writes.

Worse: `data.write(to:)` is **not atomic** — no `.atomic` option, no temp-file+rename.
A crash/kill mid-write (or two — the app is a menu-bar app the user force-quits) leaves
a truncated `drones.json`. On next launch `JSONDecoder` throws → `restoreInFlight`'s
`try?` swallows it → `inFlight` empty. Degrades rather than crashes (good), but the
persistence guarantee is silently void exactly when it mattered (unclean shutdown).

Fix: `try? data.write(to: url, options: .atomic)`, and coalesce writes (dirty-flag +
debounced `Task`, or persist once at end of sweep/flush rather than per-key). At minimum
add `.atomic`.

### [LOW] restore's own assignment fires `didSet` → immediate redundant re-write; comment is false
`restoreInFlight` line 304 `inFlight = snapshot.mapValues { … }` triggers the `didSet`
observer → `persistInFlight()` rewrites the file it just read. The doc-comment (lines
298-299) claims it "assigns to the backing storage directly to avoid a redundant persist"
— there is **no** backing store; the assignment goes straight through the observed
property. Harmless (idempotent) but a wasted synchronous startup write and a load-bearing
comment that is factually wrong (someone will trust it later). Fix: introduce a real
`_inFlight` backing var written directly in restore, or drop the false claim.

### [LOW] cache dir existence relies on every-write `createDirectory`; not guaranteed at restore-read
`persistInFlight` creates the dir before writing (fine), but `restoreInFlight` and the
whole scheme assume `cacheDir` (`repoRoot/cache`) exists. `repoRoot` is a hardcoded
`~/code/caldwell-speak` (CaldwellConfig line 30-32). On a machine where the app runs
but that path doesn't exist, every persist silently `try?`-fails forever and the feature
is a no-op with no signal. Not a crash; flag for awareness.

---

## Things that are CORRECT (checked, not bugs)
- **Deferred-removal leak**: does *not* leak. `flushDeferredRemovals` fires after **every
  line** (worker lines 716-728), re-checks `isDroneSpeaking` per pending id, and the sweep
  (line 457) + the `guard inFlight[id]==nil` in stop both clear `pendingRemoval`. All exit
  paths from `playEntry` return into the same worker loop point, so flush runs on success,
  native-fallback, and cutoff alike. Verified sound.
- **Set mutation during iteration** (line 373): Swift `Set` is a value type; the `for` binds
  a copy, mutation of `self.pendingRemoval` is safe. Correct.
- **`isDroneSpeaking`**: correctly scans `currentEntry` + `queue` by category. Correct.
- **`removedNow` Bool gating** the stop-broadcast (server 278-284): correct — deferred
  removal leaves set unchanged, later worker broadcast covers it.
- Live-probe: register→persist→stop→remove→persist all verified byte-correct on disk.

## Verdict
Speaker-linger logic is solid. Persistence is the weak seam: **the start()/configure()
ordering race (HIGH) can resurrect a stopped drone**, and the on-actor non-atomic write
(MED) is both a corruption and a throughput risk under load. Fix ordering + add `.atomic`
before shipping.
