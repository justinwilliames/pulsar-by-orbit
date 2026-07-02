# Rb-Atlas — UX Review: Drone Persistence, Linger, Codex-Imagegen, Multi-Session
Build: `pulsar-fixes` @ 346c221 | Reviewer: Atlas (UX/Behaviour)

---

## Issue 1 — [SEV-2] Ghost drones after app-closed-then-reopened: 10min "zombie show"

**What happens:** `droneStaleAfter = 600s` (10 minutes). On open, `restoreInFlight()` preserves real `lastSeen` timestamps so stale drones evict on the first sweeper tick — correct in principle. BUT: if the app was closed for *less* than 10 minutes (say 8 min), every in-flight drone from the prior session is FULLY RESTORED to the swarm with up to 2 minutes of apparent activity left. From the user's perspective: they close the lid, re-open, and see 3–5 drone heads orbiting as if work is still happening — when in reality every Claude session may have finished. The sweeper clears them within the remaining window, but until then the swarm is actively misleading.

**Root cause:** The sweep window is generous for the correct reason (a truly long-running agent shouldn't be prematurely evicted) but there's no "this drone is from a prior daemon instance" flag. A freshly-restored drone and an alive one are indistinguishable.

**Fix options:**
- On `restoreInFlight()`, mark restored drones with a "suspect" flag and apply a shorter grace window (e.g. 60s) before evicting on restore rather than using the full 600s. Real in-flight agents will re-register via SubagentStart within seconds.
- Or: on restore, evict any drone whose `lastSeen` is older than some restart-grace window (e.g. 30s) immediately, rather than waiting for the sweeper.

---

## Issue 2 — [SEV-2] codex-imagegen: drone ID collision risk between concurrent runs

**What happens:** `PULSAR_DRONE_ID="imggen-$$-${RANDOM}"`. Two concurrent `codex-imagegen.sh` runs can produce the same ID: `$$` is the PID (unique) but `$RANDOM` is only 15-bit (32767 values) — under concurrent load the IDs are practically unique. Not a real collision risk in practice (PID differs). However: `trap cleanup EXIT` in bash is `set -eo pipefail` aware — if `codex` is killed with SIGKILL (not SIGTERM), the trap does NOT fire. Kill with SIGTERM (normal `kill`) → trap fires, drone cleaned up. Kill with `kill -9` or OOM killer → drone lingers for up to 10 minutes.

**Secondary issue:** If `codex` hangs indefinitely (e.g. stuck waiting on a response), the nebula drone hovers forever. If a real `nebula` sub-agent is spawned concurrently (from a different Claude Code agent with `--agent nebula`), both land in the swarm but the view model shows ONE nebula character (deduped by category in the participant model). This is actually **correct** behaviour by design — the category represents "character", not "count". What's mildly confusing: the imagegen nebula has a fixed drone ID (`imggen-PID-RANDOM`) while the sub-agent nebula has a session-scoped ID. The claim-on-speak promotion logic correctly handles this (if one nebula is already in the map, `promoteInFlightDrone` no-ops). No visual bug, but two conceptually different tasks appear as one drone — intentional, but worth documenting.

---

## Issue 3 — [SEV-2] Multiple sessions → shared daemon → drone swarm mixing

**What happens:** The daemon is shared (singleton on port 7865). Two concurrent Claude Code sessions both fire `SubagentStart` POSTs. Drones from session A and session B appear in the SAME swarm with no session attribution. This is by design (single operator, one screen), but: Session A's agents can be "claimed" by session B's `promoteInFlightDrone` call. The claim-on-speak logic picks the **most-recently-registered** generic drone (largest `lastSeen`) — so a session B `--agent voyager` speak can promote a session A `atlas` drone to `voyager`. The Voyager head then wanders into session B's territory. Functionally harmless (one operator, one screen), but the swarm's semantic accuracy degrades under multi-session load.

---

## Issue 4 — [SEV-3] Muted user + persisted drones: panel shows swarm with no way to dismiss

**What happens:** Mute suppresses audio but NOT the floating panel. `pulsarIsPresent` = `hasInFlightDrones || playback.isPlaying`. With persisted drones restored on reopen, `hasInFlightDrones` is true → `panelShouldBeVisible` = true → panel opens and orbits restored drones. User is muted, hears nothing, sees drone heads floating over their screen with no explanation and no dismiss button. Panel will not self-hide until `tailAfterIdle` (5s) after ALL drones evict (up to 10 min). Closing and reopening the floating head panel is the only workaround.

**Fix:** When muted AND `showActiveAgents` is on, suppressing the panel open (or adding a manual-dismiss control) would respect the user's intent to have a silent session.

---

## Issue 5 — [SEV-3] Linger: the "why is it still there?" moment

**What happens:** `lingerAfterIdle = 6.0s`. A drone portrait stays centred for 6s after its last line finishes before easing back into the swarm. For a FIRST-RUN user who hasn't seen the pattern, a lingering drone after a clearly-finished sub-agent reads as a stuck/frozen UI. The 6s is intentionally generous (set "longer than `tailAfterIdle` (5s) + panel fade (0.9s)") to survive the panel fade-out, but the resulting on-screen behaviour is: drone speaks → finishes → portrait stays big and centred for 6 full seconds → slowly shrinks into orbit. There is no visual signal that the agent finished and the hold is deliberate.

**Minor note:** The RosterView's "MEET THE TEAM" section never mentions that drones appear during active work. A first-run user may dismiss the lingering portrait as a render bug before understanding the pattern.

---

## Verdict

| SEV | Area | Title |
|-----|------|-------|
| SEV-2 | Persistence | Restored drones show as "active" for up to 10min after reopen — misleading ghost work |
| SEV-2 | codex-imagegen | SIGKILL leaves nebula drone stranded; concurrent imagegen+real-nebula shows as one (correct but opaque) |
| SEV-2 | Multi-session | claim-on-speak cross-session promotion scrambles drone identity under concurrent sessions |
| SEV-3 | Muted + persistence | Swarm shows stale restored drones over muted screen with no dismiss path |
| SEV-3 | Linger UX | 6s post-speech centre-hold reads as frozen/stuck to first-run users |

**Overall:** The persistence + sweeper design is sound. The sharp edge is the 10min grace window on restore — a 30s restore-grace or "suspect on restore" flag would eliminate the most confusing case. The linger and multi-session issues are low-friction once familiar, but first-run and muted-mode paths need attention.
