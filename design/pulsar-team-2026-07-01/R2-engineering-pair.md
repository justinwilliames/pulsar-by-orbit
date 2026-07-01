# R2 — Engineering Pair (Sentinel 🛡️ + Voyager 🛰️)

Round 2 cross-reference. We ran the id contract against the **live daemon**, not synthetic JSON, and it changes the severity map materially.

## The id-contract verdict (live, settled)

**NOT reachable in practice. The session_id-collapse is theoretical, not live.** We peeked the daemon's current drone set and read both hooks against the observed payloads.

- Live drone set right now: `a4ad030549969023b`, `a7a343082deb5e115` — two **distinct** 17-hex ids.
- This review's own R1 ghosts: `a2543a6383ed49aaf`, `a16b18aa51c5988a9`, `a17088457c55d92e1` — three **distinct** 17-hex ids.
- Five sub-agents observed across two sessions → five unique per-agent ids. **Zero collisions. Never once a shared session_id.**

Claude Code **does** pass a stable, per-sub-agent `agent_id` on both Start and Stop, and it is the *same* id on both — so start/stop key symmetry holds on the real payload, and parallel fan-out renders N distinct drones. The `|| session_id` fallback in both hooks (start:36, stop:27) is **dead code on the happy path** — it only fires if `agent_id` is ever absent, which we have not been able to make happen.

**Verdict: downgrade both session_id-collapse bugs (Sentinel high / Voyager high) from "collapses parallel agents" to "latent fallback hazard."** The fix is still worth doing — *defence in depth* — because it's one line and it converts an untested assumption into a guarantee: replace `|| session_id` with `|| uuid4()` in both hooks (fail to a unique id, never a shared one). But it is **not** a launch blocker, and the three-drone chorus asking "does this collapse?" is answered: **no, it doesn't.**

## Where we agree

- **Voyager:** the category-wide `touch` (AudioQueueActor.swift:269, called HTTPServer:972) is the **real, live** integrity bug — and now that the id-collapse is demoted, it's the **#1 correctness defect.** Every `/speak --agent voyager` line refreshes `lastSeen` on *all* voyager drones, ghosts included. One live sibling keeps a dropped-Stop ghost orbiting forever. The 1800s TTL is genuinely disarmed.
- **Sentinel:** agreed, and it's worse than "forever" — it interacts with the 1800s TTL to make the ghost *look* healthy. Kill the category-wide refresh; touch only the speaking id. But that requires the `/speak` path to *carry* the agent id, which today it doesn't (only category). So this is a two-part fix: thread agent_id through the tagged-speak path, then narrow the touch.
- Both: the orphaned-`say`-temp-file leak (Sentinel crit) stands unchanged — nothing about the id verdict touches it. Purged/timed-out entries still leave AIFFs in `NSTemporaryDirectory()`.
- Both: `install-hooks.sh` has **zero** subagent lines (verified: `grep -c subagent` = 0). The manual install path ships the feature off. Structural, real, Pulsar's crit.

## Where we fight

- **Sentinel:** the TTL should stay as a bounded backstop even after reconciliation lands — a hook can always be dropped (app down at the 2s curl timeout), and a bounded sweep is cheaper to reason about than a re-assert protocol you have to prove is live-writer-correct.
- **Voyager:** disagree on emphasis — with the category-touch removed *and* a periodic `/subagent/sync` (session re-asserts its live set, last-writer-wins), the TTL becomes vestigial and its 1800s value is a lie we tell the UI. I'd keep a TTL only as a 2-hour hard-stop, not a 30-min "truth." **Resolution:** ship the touch-narrowing now (both agree); defer the TTL-vs-sync question — it's a med, not a blocker, and the sync work is post-launch.
- **Unknown→atlas (Voyager med):** Sentinel thinks it's cosmetic given the live taxonomy resolves cleanly; Voyager holds that laundering "we misclassified" into a real category is a telemetry-honesty defect. Agreed to log it, disagree on severity. Kept at med.

## Definitive de-duplicated engineering bug list (fix priority order)

1. **[crit] AudioQueueActor.swift:343/984 — orphaned `say` synth temp files.** On `timeoutEntry` + `purgeStaleWaiters`, delete any resolved temp AIFF and drop `resolvedURLs[id]`/`failedIds`.
2. **[high] install-hooks.sh (0 subagent lines) — manual install ships drones OFF.** Add SubagentStart/Stop additively; make it the single install source of truth.
3. **[high] AudioQueueActor.swift:269 + CaldwellHTTPServer.swift:972 — category-wide `touch` keeps ghosts alive, defeats TTL.** Thread the speaking agent's id through the tagged-speak path; `touchInFlightDrone(id:)` only. Drop the category broadcast-refresh.
4. **[high] SSEBroadcaster.swift:8 — unbounded `AsyncStream` buffer.** `AsyncStream(bufferingPolicy: .bufferingNewest(64))`; SSE only needs current state and `/events` replays on connect.
5. **[med] subagent-start.sh:36 + subagent-stop.sh:27 — `|| session_id` fallback is a latent collapse hazard (NOT live-reachable).** Replace with `|| uuid4()`; log the resolved id on both hooks so any future mismatch is observable, not silent.
6. **[med] AudioQueueActor.swift:619 + NativeVoiceClient.swift:227 — `waitUntilExit()` parks cooperative-pool threads per synth.** Resume from `proc.terminationHandler` (same `ContinuationBox` pattern as the afplay fix), or a 7-line burst re-exhausts the pool the afplay fix protected.
7. **[med] ClaudeIntegrationInstaller.swift:187 + CaldwellHTTPServer.swift:32 — no restart reconciliation.** SessionStart clears stale session drones; add a periodic `/subagent/sync` re-assert.
8. **[med] subagent-start.sh:71 — unknown agent_type → `atlas` overloads two meanings.** Give unknowns a distinct `unknown` category/badge.
9. **[low] AudioQueueActor.swift:836 — synchronous `afinfo` + `waitUntilExit()` on the actor executor.** `Task.detached` it like `extractEnvelope`.

## One compound bug that needs both lenses

**Category-wide touch (Sentinel's lifecycle lens) × dropped-Stop with no reconciliation (Voyager's state-model lens) = the permanent ghost.** Neither half is fatal alone: a dropped Stop *should* self-heal in ≤30 min via the sweeper (Voyager's model), and the category-touch is *harmless* if every drone's Stop always lands (Sentinel's lifecycle). But composed, they deadlock the sweeper: the touch resurrects the very ghost the TTL exists to reap, and with no reconciliation nothing else ever corrects it. This is why it survived R1 review from either lens in isolation — you have to hold both the "who refreshes lastSeen" (concurrency) and the "what is the map's source of truth" (data) questions at once to see the ghost is *immortal*, not just long-lived. Fix #3 breaks the loop; fix #7 makes it converge on truth regardless.

— Sentinel 🛡️ (concurrency / lifecycle / debuggability)
— Voyager 🛰️ (state-model integrity / id contracts / reconciliation)
