# R1 — Sentinel (Engineering lens)

**Verdict:** Ships, but three concurrency/lifecycle bugs will leak audio spend, orphan drones on parallel spawns, and grow SSE buffers unbounded under a slow client — none caught by tests that never exercise the failure path.

## BUG LIST

**[crit] AudioQueueActor.swift:343 / 984 (enqueue drop) — orphaned `say` synth on a full/busy queue.**
WHY: `/speak` and `/canon/pick` `enqueue()` FIRST, then spawn the detached `NativeVoiceClient.synth` Task only *after* a non-nil position. Fine here — BUT `/history/replay` and `/cache/play` enqueue an entry that already carries a temp file; if `enqueue` returns nil (queue full / stale-purge race) they clean up the temp, good. The real leak: on the `/speak` path, `enqueue` can return a position, the worker later *purges the entry as a stale waiter* (>60s) or the watchdog skips it, yet the detached synth Task still runs to completion and calls `markReady`, writing an AIFF into `resolvedURLs[id]` that no worker will ever remove. Those temp AIFFs accumulate in `NSTemporaryDirectory()` for every purged/timed-out line. FIX: on `timeoutEntry` and in `purgeStaleWaiters`, drop `resolvedURLs[id]`/`failedIds` and delete any temp file already resolved for that id.

**[high] AudioQueueActor.swift:246 + subagent-start.sh:36 — parallel sub-agents in one session collide on `session_id`, and the 1800s TTL makes the ghost permanent for the whole session.**
WHY: both hooks resolve id as `agent_id || agentId || session_id`. If Claude Code omits a per-agent id (unverified against a live payload — see prior R1), every parallel drone keys on the SAME `session_id`: `inFlight[id]=` overwrites, so N drones render as 1, and the FIRST Stop removes it while N-1 keep running invisibly. The 1800s TTL (raised from 90s) means a genuinely leaked drone now orbits for a full 30 min — effectively the whole work session. The TTL "fixed" the silent-long-runner sweep by trading it for a near-permanent ghost. FIX: require a real per-agent id at the hook (fail closed / synthesise a uuid per Start invocation), and key `inFlight` on that; keep TTL as backstop only.

**[high] SSEBroadcaster.swift:8 — `AsyncStream` uses the default `.unbounded` buffer; a slow/stalled `/events` client grows memory without limit.**
WHY: `makeStream()` creates `AsyncStream<String>` with NO `bufferingPolicy`, which defaults to `.unbounded`. `broadcast()` calls `continuation.yield` for EVERY event (voice_active carries a full envelope array) to EVERY continuation, never checking the yield result. A UI that connects then stops draining (backgrounded tab, wedged socket, sleep/wake before `onTermination` fires) buffers every event forever inside the actor. Over a busy day of drone chatter that's real heap growth with no ceiling. FIX: `AsyncStream(bufferingPolicy: .bufferingNewest(64))` and drop oldest — SSE clients only need current state, and `/events` already replays full state on connect.

**[med] CaldwellHTTPServer.swift:701–705 — `/settings` POST broadcast can loop the UI's own writes back / echo storm.**
WHY: every settings write (including `say.sh --mute` fired by a hook every turn) broadcasts `settings` to all clients. The UI's `toggleMute` optimistically flips local state then POSTs, which broadcasts back and re-decodes into `settings` — harmless idempotently, but there's no de-dupe: a burst of `--mute/--unmute` or rapid canon-toggle writes fan out one broadcast each to N streams with no coalescing. Low blast radius today; will bite when settings writes get chattier. FIX: only broadcast when the persisted value actually changed.

**[med] AudioQueueActor.swift:619 + NativeVoiceClient.swift:227 — two `Task.detached { proc.waitUntilExit() }` blocking waits survive the very fix the file documents.**
WHY: `playEntry` correctly moved afplay off blocking-wait to `terminationHandler` (the documented "stops after 2 lines" fix). But `extractEnvelope` runs in a detached task that reads the whole PCM file synchronously, and `NativeVoiceClient.synth` STILL parks a cooperative-pool thread on `proc.waitUntilExit()` per synthesis. Under a 7-line burst that's 7 concurrent blocking parks on the same pool the afplay fix was protecting — the exact exhaustion the comment warns about, reintroduced on the synth side. FIX: resume synth from `proc.terminationHandler` too, same `ContinuationBox` pattern.

**[low] AudioQueueActor.swift:836 `audioDuration` — synchronous `afinfo` + `waitUntilExit()` on the actor's executor.**
WHY: called from `playEntry` (actor-isolated) before each line; blocks the actor on a subprocess round-trip, serialising all queue mutation behind it. Small per-line, but it's actor-blocking I/O. FIX: `Task.detached` it like `extractEnvelope`.

## Highest-priority fix
The orphaned-synth temp-file leak (crit) — it silently fills `/tmp` on exactly the burst/stale path the queue is designed to survive, and nothing tests it. Wire temp cleanup into `timeoutEntry` + `purgeStaleWaiters`.

## Question for another drone (Voyager / data)
Against a REAL Claude Code `SubagentStart`/`SubagentStop` payload — not synthetic JSON — is there a stable per-agent id distinct from `session_id`, and does the SAME id reach the `say.sh --agent` narration path? If not, every parallel fan-out collapses to one drone and the whole active-speaker swap is unverifiable end-to-end.

— Sentinel 🛡️
