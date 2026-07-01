# R2 — Pulsar (CoS Synthesis): What the Team Is Collectively Missing

**Lens:** not the bugs — the seams between them. Who owns nothing, where findings compound, where two drones are about to hand Justin conflicting fixes, and the one thing that makes every other fix cosmetic.

---

## The one thing that makes everything else cosmetic

**The id contract is unverified, and nobody captured the payload.** Sentinel, Voyager, and I each independently flagged it; Voyager was assigned the capture last round and it still hasn't happened. Every other drone-related fix — Nova's home-arc lane, Atlas's ghost-panel gate, Echo's install wiring, Sentinel's `inFlight` keying, Voyager's category-touch — assumes a real, stable, per-agent id flows identically through **Start hook → Stop hook → `say.sh --agent` narration**. If it doesn't (if parallel agents collapse onto `session_id`), then N drones render as one, the first Stop kills the group, the "pass-the-baton" swap Nova is polishing has nothing to swap between, and every activation fix Echo ships lights up a feature that silently no-ops on exactly the multi-agent runs it's built for. **Fix order is not negotiable: capture one real multi-agent `SubagentStart`/`SubagentStop` payload BEFORE touching any collapse/swap/keying bug.** One artefact settles four bugs at once. Without it, we are polishing pixels on a mechanic we haven't proven fires.

---

## What NO drone owns (the unowned gaps)

1. **Test coverage for the daemon and hooks.** Six drones found bugs on the failure path — orphaned synth, category-touch resurrection, start/stop key asymmetry, ghost panels — and Sentinel said it out loud: "none caught by tests that never exercise the failure path." Nobody proposed a test harness. Every fix we ship this round is unregression-guarded. **Owner needed: Sentinel — a minimal hook-payload + queue-lifecycle test before we call any of this fixed.**

2. **Second-machine verification.** My R1 crit (installer drift) and Echo's crit (six-star activation path) are the SAME finding from two lenses: *the whole team verified on Justin's laptop, where the in-app installer already patched settings.json.* No one has done a clean-clone → README-install → does-a-drone-appear run. Voyager's "no reconciliation on restart" bug is invisible from a warm machine too. **Owner needed: someone who is not Justin, on a machine that has never run the app.**

3. **The merge itself.** The branch is 40+ commits ahead, dirty, unpushed, no tag, no DMG. Every drone reviewed code that doesn't exist anywhere but this checkout. Reviewing an unmerged branch is reviewing a draft. **Owner: Justin — decide the merge-to-main gate; nothing else lands until this does.**

---

## Where findings COMPOUND (bigger than any single bug)

- **There is no install story at all.** My installer-drift crit + hardcoded `/Users/justin/...` hook paths + no uninstaller + Echo's six-step silent-failure chain + the Gatekeeper quarantine trust-gap are not five bugs — they are one absence. A user who follows the README gets dead symlinks to a source checkout they don't have, the drone hooks switched off, no way to remove what did install, and total silence with no error. "Works on my machine" is the *entire* install experience for user #2.

- **The rename is a first-impression failure, not naming debt.** Nebula's two crits (About says "Caldwell," expletives default ON) + my `CaldwellDashboard` process/target debt compound into: *a first-time user meets a swearing bot named Caldwell inside a Pulsar-branded window.* Individually cosmetic; together they mean the product fails its own opening frame.

- **Truth-by-timeout is disarmed by its own refresh.** Voyager's category-wide `touch` + start/stop key asymmetry + no restart reconciliation = the 1800s TTL (the thing last round bought to self-heal ghosts) can never fire as long as one same-category sibling ever speaks. The safety net has a hole exactly where the fall happens.

---

## Where two drones will hand Justin CONFLICTING fixes (decisions needed)

1. **Atlas vs the id fix on the ghost panel.** Atlas wants `recomputePanelVisibility` to gate on renderable content (a UX patch at the panel layer). But if Voyager/Sentinel's id-and-reconciliation fix lands, the "empty participants" state Atlas is guarding against partly disappears at the source. **Decision: fix the ghost panel at the data layer (id/reconcile) first, THEN let Atlas's content-gate be the backstop — don't build the UX patch against a bug we're about to remove upstream.**

2. **Atlas-as-real-drone vs Atlas-as-`unknown`-bin.** Voyager and Nebula both want unknown agents to stop laundering into `atlas` — but split on the fix: Voyager wants a distinct `unknown` category (own colour/badge); Nebula wants Atlas *promoted* to a real ops remit with unknowns falling to Pulsar. These are mutually exclusive taxonomies. **Justin decides: is Atlas a character or a catch-all? Everything downstream (colour wheel, voice casting, drone count) forks on this one call.**

---

## Dependency order (what unblocks what)

1. **Capture the live payload** (Voyager) → unblocks all keying/collapse/swap/reconcile work.
2. **Wire drone hooks into `install-hooks.sh` + resolve paths to `~/.claude/skills`** (me) → unblocks every activation/first-run fix Echo and Atlas proposed; until this lands, their fixes light up a feature that isn't installed.
3. **Decide Atlas's identity** (Justin) → unblocks Nebula's colour wheel + voice casting + Nova's per-category home-arc index (which keys on `DroneRegistry.categories`).
4. **Then** the render polish (Nova), the rename (impl), the UX legibility (Atlas), the story (Echo) — all safe once they build on a proven, installed, correctly-keyed foundation.

The fix that makes the rest real is #1. The fix that makes the rest *reachable by a user* is #2. Everything the other five drones wrote is downstream of those two — genuinely good work, aimed at a foundation we haven't yet nailed down.

— Pulsar 🔵 *(what's the blocker, and who owns it by Friday?)*
