# Pulsar Team Review — Action Plan (R4)
**Date:** 2026-07-01 · **Target:** Pulsar app + drone swarm (`~/code/caldwell-speak`, branch `pulsar-drones`) · **Orchestrator:** Pulsar seat
**Inputs:** 7× R1 solo diagnoses, 4× R2 cross-references (all in this dir).

---

## What the team agreed on

1. **The drone swarm is invisible to every real install.** `install-hooks.sh` contains zero SubagentStart/Stop wiring — the feature exists only because the in-app Swift installer patched *this* machine. Flagged independently by Pulsar, Echo, Sentinel, Voyager, and the story pair (5 drones). This is the headline. Everything about the feature is cosmetic until this ships.
2. **The rename is half-done and the first impression is off-brand.** About card still says "Caldwell"; the persona's expletive default is a split-brain (`SKILL.md` = true, daemon persists true, Swift fallback = `?? false`) so nobody actually decided it; `CaldwellDashboard` leaks through bundle name, executable, classes, `CALDWELL_*` keys.
3. **The id-contract fear was falsified.** Three drones flagged "parallel agents collapse on `session_id`." The engineering pair verified against live daemon data: five sub-agents → five distinct per-agent ids, zero collisions. **Not live-reachable.** One-line defensive fix only. The ghost/dup problem is NOT id-collapse — it's the immortal-ghost bug (below).
4. **The real ghost bug is the category-wide TTL touch.** `AudioQueueActor.swift:269` refreshes *every* same-category drone whenever one speaks — so a ghost atlas riding beside a live one never ages out. This is why the earlier 1800s-TTL "fix" didn't hold and why Justin saw 3 atlases.
5. **No tests, one machine, unmerged.** Every drone found failure-path bugs; nobody found a test guarding them. Everything was verified on Justin's warm laptop where the installer already ran. The branch is 40+ commits ahead, dirty, unpushed.

---

## Shippable now (next 48h) — verified, owned, low-risk

| # | Fix | File:line | Sev | Owner (lens) |
|---|-----|-----------|-----|--------------|
| 1 | **Wire drone hooks into `install-hooks.sh`** additively (SubagentStart→subagent-start.sh, SubagentStop→subagent-stop.sh); make it the single source of truth | `scripts/install-hooks.sh` | crit | Sentinel/orch |
| 2 | **Delete orphaned `say` temp AIFFs** — drop `resolvedURLs[id]`/`failedIds`, delete the temp in `timeoutEntry` + `purgeStaleWaiters` | `AudioQueueActor.swift:343,984` | crit | Sentinel |
| 3 | **Kill the immortal ghost** — thread agent id through tagged-speak; `touchInFlightDrone(id:)` refreshes only the speaking drone, drop the category-wide touch | `AudioQueueActor.swift:269` + `CaldwellHTTPServer.swift:972` | high | Voyager |
| 4 | **Finish the rename** — About card "Caldwell"→"Pulsar"; CFBundleName/executable/`CALDWELL_*`/class names → Pulsar | `AboutView.swift:32`, `Info.plist`, targets | crit(brand) | Nebula |
| 5 | **Decide the persona default once** — Polite as the single authored default in SKILL.md *and* the daemon's persisted default; Potty opt-in (matches the `?? false` code, fixes the ambush) | `SKILL.md:3,33` + daemon default | crit(brand) | Nebula/Echo |
| 6 | **Bound the SSE buffer** — `bufferingPolicy: .bufferingNewest(64)` | `SSEBroadcaster.swift:8` | high | Sentinel |
| 7 | **Gate the ghost panel** — `panelShouldBeVisible` also requires `!participants.isEmpty || captionWouldShow` (no more empty 5s window when showAgents off) | `FloatingHeadsView.swift:270`, `DashboardViewModel` | high | Atlas |
| 8 | **Fix the speaker arc-lane collision** — stable per-`Participant.id` arc index from `DroneRegistry.categories` (incoming/outgoing stop sharing lane 0) | `FloatingHeadsView.swift:210` | high | Nova |
| 9 | **Icon-state event, not settings storm** — targeted `{type:"icon-state",muted}` SSE only on mute-state *change* (fixes stale icon; no echo-storm) | `CaldwellHTTPServer.swift` | high | Atlas+Sentinel |
| 10 | **Spread the drone hues** — push Atlas off slate-blue (Sentinel azure + Atlas slate collide at 52px); even six-hue spacing | `DroneRegistry.swift:77,85` | high | Nova/Nebula |

## Queue for the week (reversible, deserves a sprint)

- **Uninstaller** for the `~/.claude/settings.json` hook edits + in-app "Remove integration" (no revert path today). — orch · high
- **Portability** — resolve hook paths off hardcoded `/Users/justin/...` to `~/.claude/skills/pulsar/scripts`. — orch · high
- **First-run activation** — default popover to an empty-state with "Meet the team →"; "voice is live" green-tick on first `/speak`; the README one-liner ("Your AI tells you when it's done — stop watching the screen") under the header. — Atlas/Echo · high
- **Animate the repack** — `matchedGeometryEffect`/`withAnimation` on idle-cluster + speaker→idle transitions (stop the position snap). — Nova · med
- **Blink reset** on `droneName` change (`blinkStart=-1`, defer `nextBlinkAt`). — Nova · med
- **`waitUntilExit` → `terminationHandler`** in `NativeVoiceClient.synth:227` (stop parking pool threads). — Sentinel · med
- **Defence-in-depth id fallback** — `|| uuid4()` not `|| session_id` in both hooks; log the resolved id. — Voyager · med
- **Toggle-disabled labels** ("Requires Floating Head"), **reduce-motion** on panel fade, **rim-glow clip** at panel edge. — Atlas/Nova · med
- **Tests** — first daemon/hook test (start→stop pairing, sweeper eviction, id resolution). — Sentinel · high(process)

## Defer (with justification)

- **session_id-collapse rework** — verified not live-reachable; the one-line uuid4 fallback covers it. Deeper rework would be solving a bug that can't fire.
- **"Signature pulse" move** (idle heartbeat + speech-synced brightness) — genuinely good (Nebula), but it's a feature, not a bug; ship the fixes first.
- **Restart reconciliation `/subagent/sync`** — real gap, but with the immortal-ghost fixed and TTL as backstop, ghost lifetime drops from ∞ to one TTL; full reconciliation can wait.

## Decisions needed (Justin)

1. **Is Atlas a character or a catch-all?** Voyager: give unknown types a distinct `unknown` category, keep Atlas as a real generalist. Nebula: promote Atlas to a real ops remit and route unknowns to Pulsar. Mutually exclusive — colour wheel, voice casting, and drone count all fork on it. *(Pulsar's rec: distinct `unknown` bin — cleanest, keeps Atlas a real character; unknowns shouldn't cosplay a named drone.)*
2. **Persona default for a shipped app: Polite or Potty?** The team is unanimous that a stranger's first line shouldn't be profanity pre-opt-in → **default Polite, Potty opt-in.** Your personal chat persona is unaffected; this is only the shipped default for new users. Confirm.
3. **Drone story: motion or micro-copy?** Nebula: tell it by motion (the pulse + centre-step), no explanatory chrome. Echo: one-line prime as a floor until motion carries it. Both agree the pulse is the signature move. *(Rec: ship Echo's one line now, build Nebula's pulse next — floor then ceiling.)*

## Open questions carried forward

- Who verifies on a **cold second machine** (not Justin's)? Installer drift + activation failures are invisible from the warm laptop.
- What's the **merge/release gate** — commit the 12 PNGs, tag, cut a DMG?

---
*Synthesized by the Pulsar orchestrator seat from 11 drone artifacts. The 3-atlas bug Justin hit is now fully explained: immortal-ghost (category-touch, #3) × all-general-purpose-spawns-collapse-to-atlas (the review's own agents) — both have fixes above.*
