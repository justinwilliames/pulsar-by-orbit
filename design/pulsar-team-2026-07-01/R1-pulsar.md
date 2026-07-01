# R1 — Pulsar (Chief of Staff / Orchestrator lens)

**Lens:** ship-or-no-ship, dependency tracking, who-owns-what-by-when, the assumption everyone's quietly making. *What's the blocker, and who owns it by Friday?*

## Verdict
**HOLD for merge/push — CONDITIONAL for Justin's own machine.** It runs beautifully on this laptop and nowhere else. The branch is 40+ commits ahead of main, unmerged, unpushed, with a dirty tree — and the "it's wired now" win is wired by the *in-app* installer only, so the release path a user actually follows ships the feature switched off. Prior review's #1 blocker is resolved *locally* and still open *structurally*.

## RISK LIST

**[SEV crit] release / installer drift — the manual installer silently omits the entire drone feature.**
WHY: `scripts/install-hooks.sh` wires Stop/SessionStart/chime/turn-start/statusline and `grep -c subagent` = **0**. Only `ClaudeIntegrationInstaller.swift` (the in-app button) adds SubagentStart/Stop. Justin's live `settings.json` has the drone hooks *because the app wired them* — but the README tells users to run `install-hooks.sh`, which never will. Priya flagged this exact drift last round; it's unreconciled. OWNER+FIX: **orchestrator, before merge** — make `install-hooks.sh` the single source of truth and add the two drone hooks additively; pick ONE installer.

**[SEV crit] release / branch state — nothing is shipped, and the tree is dirty at review time.**
WHY: `pulsar-drones` is unmerged, unpushed to origin; 12 modified drone PNGs sit uncommitted and this review dir is untracked. There is no tag, no DMG, no release note for the feature. "Built fast over 2 days" has no landing strip. OWNER+FIX: **Justin** — commit/stash the PNGs, decide merge-to-main gate, cut a versioned build; the CI badge in README points at a workflow that's never run this feature.

**[SEV high] portability / "works on my machine" — hardcoded dev-checkout paths are the install contract.**
WHY: live `settings.json` hooks are absolute `/Users/justin/code/caldwell-speak/...`; README step 5 is `ln -s ~/code/caldwell-speak`. A second user cloning the public repo gets dead hook paths and a symlink to a directory that doesn't exist. The app ships to a `.app` bundle but the hooks reference the *source checkout*. OWNER+FIX: **orchestrator** — hooks must resolve to the installed skill dir (`~/.claude/skills/pulsar/scripts`), which the Swift installer already stages; kill the source-tree assumption in README.

**[SEV high] reversibility / hooks — the app edits the user's `~/.claude/settings.json` and there is NO uninstaller.**
WHY: `grep uninstall|revert|restore` across scripts + Sources = nothing. Both installers back up (timestamped `.pulsar-bak`), but a backup is not a revert — no path restores it, and the user who tries Pulsar and bails is left with five-plus hooks and a statusLine in their global config, forever, by hand. For a tool that modifies the config every session, one-click removal is table stakes. OWNER+FIX: **orchestrator** — ship `uninstall-hooks.sh` + an in-app "Remove integration" that strips only Pulsar-managed keys.

**[SEV high] id contract — three drones have now asked the same unanswered question; nobody owns answering it.**
WHY: Sentinel, Voyager and last round's Priya all flag it: is there a stable per-agent id in the REAL `SubagentStart`/`SubagentStop` payload, distinct from `session_id`, and does it match the id `say.sh --agent` uses? Still verified only against synthetic JSON. Until someone captures a live payload, every parallel fan-out may collapse to one drone and the signature swap may silently no-op. This is a *decision without an owner* — my pet hate. OWNER+FIX: **Voyager, this round** — capture one real multi-agent session's payloads; that single artefact settles Sentinel's and Voyager's crit/high bugs at once.

**[SEV med] naming / identity debt — the binary, resource bundle and process are still `CaldwellDashboard`.**
WHY: bundle id and display are `Pulsar` / `team.yourorbit.Pulsar` (good), but `Contents/MacOS/CaldwellDashboard`, the `.bundle`, launchd migration, and the Swift module are all still Caldwell. Public MIT repo named `pulsar-by-orbit` shipping a `CaldwellDashboard` process is a rename left half-done. OWNER+FIX: **impl agent, post-merge** — rename the target or accept the debt explicitly, don't leave it ambient.

**[SEV med] sanitization / public repo — "Sir" survives in README (×2) and SKILL.md (×1).**
WHY: standing rule is strip persona honorifics from public/customer-facing artefacts. A public repo's front page still reads *"Pushed, Sir."* OWNER+FIX: **Echo** — sanitize README/SKILL canon examples before push.

**[SEV low] reproducibility / assets — the 4-regen drone-frame pipeline is a one-off.**
WHY: dozens of commits ("regen reframe", "composited over masters", "scale to 1.12") mutated PNGs in-tree with no committed script. Re-deriving a 7th drone or a tweak means redoing the hand-process from memory. OWNER+FIX: **Nebula** — commit the regen/reframe/composite step, even a rough one.

## The single biggest UNOWNED risk
**The gap between "the app wired it" and "the documented install wires it."** Everyone verified drones by watching Justin's machine, where the *in-app* installer had already patched settings.json — so the crit installer-drift risk is invisible from inside a working demo. No owner is assigned to reconcile the two installers or fix the README's dead symlink, because from where everyone's standing it already works. That's the assumption everyone's quietly making: *"it's wired"* — true here, false for user #2.

## Question for another drone (Voyager)
You own the live-payload capture. When you grab it, also confirm: does a fresh clone → README install (`install-hooks.sh` + symlink) produce a single working drone end-to-end **without** ever clicking the in-app installer? If no, the manual path is decorative and we have one install path, not two.

— Pulsar 🔵 *(what's the blocker, and who owns it by Friday?)*
