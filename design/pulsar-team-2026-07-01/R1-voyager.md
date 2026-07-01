# R1 — Voyager (Staff Backend / Data Engineer)

**Lens:** state-model integrity, lifecycle symmetry, telemetry that records outcomes not actions. *What does the data actually say?*

## Verdict
The TTL/sweeper/replay wiring the last review demanded is now IN — but it papered the leak with a timeout and then quietly disarmed the timeout: a category-wide `touch` keeps ghosts alive, start/stop key asymmetry still orphans, and there is still zero reconciliation with what Claude Code is actually running. The model is more honest than before and still cannot tell you the truth on demand.

## Bug list

**[SEV high] AudioQueueActor.swift:269–275 (+ CaldwellHTTPServer.swift:971) — category-wide `touch` resurrects ghosts, defeating the TTL.**
WHY: `touchInFlightDrones(category:)` refreshes `lastSeen` for EVERY in-flight drone of a category on any `/speak --agent <cat>` line. One live `voyager` narrating resets the 1800s clock on a *ghost* voyager whose Stop was dropped. As long as any same-category sibling ever speaks, the sweeper can never reap the ghost. Truth-by-timeout, then timeout defeated.
FIX: only `touchInFlightDrone(id:)` by the speaking agent's id; drop the category-wide broadcast-refresh, or make it refresh only the single narrating drone.

**[SEV high] subagent-start.sh:36 vs subagent-stop.sh:27 — start/stop agent_id resolution is a silent orphan factory.**
WHY: both resolve `agent_id or agentId or session_id`. If Claude Code populates a real `agent_id` on Start but that field is absent/renamed on Stop (or vice-versa), Start keys the drone under the agent id and Stop deletes under `session_id` → `removeInFlightDrone` misses → orphan until the 1800s sweep (if it ever fires — see above). Start and Stop MUST agree on the key; nothing guarantees they do.
FIX: pin ONE canonical id field for both hooks; log the resolved id on each so a mismatch is observable, not silent.

**[SEV high] AudioQueueActor.swift:249 — duplicate/empty agent_id collapses parallel agents into one drone.**
WHY: `inFlight[id] = InFlightDrone(...)` overwrites. Two parallel same-session agents with empty `agent_id` both fall back to `session_id` → identical key → one drone renders for two agents. The FIRST Stop removes it; the second agent runs invisibly and its Stop is a no-op. Counts lie; a live agent has no drone.
FIX: require a per-agent unique id at the hook (fall back to a random UUID, never `session_id`); reject/namespace empty ids server-side.

**[SEV med] ClaudeIntegrationInstaller.swift:187 + CaldwellHTTPServer.swift:32 — no reconciliation on app restart; live agents never appear.**
WHY: `inFlight` is in-memory. App restart mid-session → set empties. Agents already fired Start (lost) and will only fire Stop against an empty map (no-op) → those live drones NEVER show for their whole run. There is no SessionStart-side "clear + re-register" and no periodic reconcile against Claude Code's actual agent set. The daemon's belief and reality can only converge by luck.
FIX: add a lightweight re-register (SessionStart clears stale session drones) or a `/subagent/sync` the session periodically re-asserts its live set to.

**[SEV med] subagent-start.sh:65–72 — unknown agent_type → keyword-guess → `atlas` overloads one bucket with two meanings.**
WHY: an unrecognised `agent_type` with no prompt-keyword hit silently becomes `atlas`. So `atlas` means BOTH "true generalist" AND "we had no idea." Every mystery agent renders an identical Atlas drone — indistinguishable dupes, and the taxonomy asserts a category it doesn't know. Telemetry logs the *action* (a drone appeared) not the *outcome* (we misclassified).
FIX: keep a distinct `unknown` category (own colour/badge) so a misroute is visible, not laundered into Atlas.

**[SEV low] AudioQueueActor.swift:261–264 — `touchInFlightDrone` no-ops if start was lost, so a narrating drone with a dropped Start is never shown.**
WHY: guard `inFlight[id] != nil` means a tagged line can't register a drone whose Start POST failed (app down at spawn, 2s curl timeout). Deliberate ("a tagged line never resurrects"), but combined with no reconciliation it means a dropped Start = permanently invisible agent even while it actively narrates.
FIX: acceptable if reconciliation lands; otherwise let a tagged line lazily register an untracked id.

## Single highest-priority fix
Kill the category-wide `touch` (bug 1) and pin one canonical id across both hooks (bug 2). Together they are the difference between "the TTL self-heals a ghost in ≤30min" and "the TTL never fires and the orphan is permanent." The sweeper the last round bought is currently disarmed by its own refresh path.

## Question for another drone (Sentinel / eng)
The 1800s TTL is a data-integrity smell — truth-by-timeout. If we instead made the session periodically re-assert its live agent set (`/subagent/sync`, last-writer-wins), could we drop the TTL entirely and let reconciliation be the ONLY truth source — or does the hook cadence make a bounded TTL still necessary as a backstop?

— Voyager 🛰️
