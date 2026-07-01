# R4 — Action Plan (drones UX hardening), 2026-07-01

Seven-lens review of the Pulsar sub-agent drones feature. Strong convergence.

## What the team agreed on
- The swap is the **signature move** but is currently performed as a **crossfade**, not a trade of places. Make it a real pass-the-baton.
- The cast is a **well-cast bible performed as a swatch book** — siblings differ in hue/voice but move identically. Give each a signature motion.
- Underneath the polish, the **in-flight set can lie** (no TTL/liveness) and the **real wire isn't connected** (hooks → daemon) — so it's demo-ready, not ship-ready.

## Shippable tonight (priority order)
1. **Wire real hooks (BLOCKER, owner: orchestrator).** `settings.json` SubagentStart/Stop call telemetry scripts, not `subagent-start/stop.sh`. Add the drone scripts additively; capture the real `agent_id` payload; one real end-to-end session must show a drone. [Priya, Sloan Q, Han #3]
2. **True place-swap (owner: impl agent).** Matched arcs — drone orbit→centre while Pulsar centre→its pinned orbit slot, same spring; stagger springs (in .38/.62 overshoot, out .55/.74); entry scale 0.85→0.72. [Aja, Marcus, Yuki, Devi]
3. **State honesty (impl agent).** `lastSeen` per in-flight entry (set on Start, refresh on each `say --agent`), ~1 Hz sweeper evicting >90 s + re-broadcast, replay `drones_in_flight` on `/events`, graceful fade on eviction. [Han]
4. **One speaker snapshot (impl agent).** Collapse the 4 swap signals into a single view-model `activeSpeaker {id,category,color,amplitude}`; centre/namecard/bubble read only it. Kills desync/flicker. [Sloan]
5. **Name card (impl agent).** Below the centre portrait, "NAME · ROLE", 10–11pt semibold +tracking, real strokeBorder (blur dissolved it), shadow ~8. [Yuki, Marcus, Devi, Aja]
6. **Colour distinctness (impl agent).** Echo→(.18,.75,.72), Sentinel→(.42,.72,.92), Atlas→(.50,.55,.80); + a non-colour role badge. [Marcus, Yuki]
7. **Per-drone signature motion (impl agent).** Motion trait in DroneRegistry — explorer restless/wide, reviewer still, builder bouncy, etc. [Aja]
8. **Perf + a11y + clutter (impl agent).** Idle drones throttled ~20 fps, honour Reduce Motion, cap visible at 3 + "+N" overflow badge (orbit collides past ~4). [Sloan, Yuki, Marcus, Devi]

## Owner split
- Orchestrator: #1 (hooks + real payload + end-to-end), final visual QA.
- Impl agent (warm context): #2–#8, build + commit on `pulsar-drones`.

Full per-persona critiques: `R1-*.md` in this directory.
