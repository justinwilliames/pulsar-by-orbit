# R1 — Han Müller (Staff Backend / Data Engineer)

**Lens:** state-model integrity, failure-mode honesty, telemetry that records outcomes not actions.

## Verdict
The overlay is a **liar by construction** — `inFlightDrones` is an append/remove set with no TTL, no liveness, and no session scope, so it drifts away from "what's actually running" on the first dropped Stop hook and never recovers. Pretty swap, dishonest model.

## Top 3 findings

**1. Leaked drones are permanent — the set only shrinks on a clean Stop.**
`AudioQueueActor.inFlight` (lines 185–195) is mutated *exclusively* by `/subagent/start` (add) and `/subagent/stop` (remove). The Stop path is best-effort and silent: `subagent-stop.sh` exits 0 on any failure, `curl --max-time 2 ... || true`. A crashed sub-agent, a killed Claude session, a SIGKILL, a 2s timeout, or the app being down at Stop-time all mean **the Stop POST never lands and the drone orbits forever.** There is no reaper, no TTL, no heartbeat. Over a long day of fan-out work the orbit fills with ghosts of agents that finished hours ago — the worst kind of cache: one that papers over dead state and looks confident doing it.

**2. The daemon restart wipes the set; a reconnecting UI keeps stale ghosts. Asymmetric and both wrong.**
`inFlight` is in-memory only. App restart → set is empty, but real sub-agents spawned by a still-running Claude session already fired their Start (gone) and will fire Stop against an empty set (no-op) → **those live drones never appear.** Conversely, `/events` (CaldwellHTTPServer lines 338–341) replays only `connected` + `state` — **never `drones_in_flight`.** So a UI that reconnects (SSE drop, sleep/wake) holds whatever `inFlightDrones` it last had and gets no correction until the next start/stop. Restart loses live drones; reconnect keeps dead ones. The set is authoritative nowhere.

**3. agent_id collisions and category mapping degrade *silently*, not gracefully.**
- **Duplicate agent_id:** `inFlight[id] = category` overwrites. Two agents, one key → one drone, and the *first* Stop removes the survivor while the other keeps running invisibly. The hook falls back to `session_id` when `agent_id` is absent (both scripts) — parallel sub-agents in one session can collide on that.
- **Unknown agent_type:** mapping is honest-ish but lossy — unknown type with no keyword hit → silently "atlas". So atlas is overloaded: it means *both* "true generalist" and "we have no idea." The overlay asserts a category it doesn't actually know.
- The UI lowercases/`isDrone`-guards everything (good), so a garbage category degrades to Pulsar-indigo rather than crashing — that half is fine.

## Single highest-impact fix
**Make Start the source of truth and give every drone a TTL.** Stamp each `inFlight` entry with `lastSeen: Date` on Start; have `say.sh --agent <cat>` (and any drone line) refresh it. Run a 1-Hz sweeper in the actor that evicts entries older than ~90s and re-broadcasts. Add `drones_in_flight` to the `/events` replay so every (re)connect gets the true current set. Net: a leaked drone self-heals in ≤90s, restart re-converges, reconnect corrects. The model stops lying without needing the Stop hook to be reliable — which it provably isn't.

## One question for another lens (UX / Marcus)
When a ghost drone is reaped after 90s of silence, what should the *eviction* read as on screen — a graceful fade-to-orbit-exit, or instant pop? A hard despawn mid-session may look like a bug even when it's the model finally telling the truth.
