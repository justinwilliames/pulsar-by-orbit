# R2 — Design Pair Review (Atlas × Nova)
**Pulsar Drones · pulsar-drones branch · 2026-07-01**

---

## Where We Agree / Where We Fight

**Agree — ghost panel is the #1 user-facing failure.**
Atlas (UX): the empty floating window is the most jarring first impression — a deliberate user setting (`showActiveAgents OFF`) producing a visible consequence the user can't explain.
Nova (craft): agreed on priority; also flags that this failure is compounded by the rim-glow clipping that would affect the bubble even if the panel *had* content. Fix the gate first, then the margin.

**Agree — blink-state bleed and the arc-lane collision are both "baton-pass broken" bugs.**
Both surface during the headline mechanic. A smear-through-the-same-pixel swap AND a blink firing mid-face-swap = the ensemble cast reads as one glitchy head, not a team.

**Agree — idle cluster repack is a hard snap that undercuts perceived quality.**
Atlas: snap = cognitive surprise, user thinks something crashed. Nova: snap = fails the "earn the pixel" bar for a premium app.

**Fight — default tab.**
Atlas wants `.roster` as the default so drones are discoverable on first open.
Nova pushes back: `.roster` on first open shows empty slots and static portraits with no context — it's a cast list for a show the user hasn't seen yet. Counter-proposal: keep History as default BUT add an empty-state in the history panel with a "What is Pulsar? Meet the team →" inline prompt that navigates to Roster. The user's first open should answer the implied question ("did anything happen?") then offer discovery, not show a blank team sheet.
**Resolution:** Atlas concedes Nova's point. History default + guided empty-state is the right flow. The empty-state copy is the fix, not a tab swap.

**Nebula cross-reference:**
Nebula flagged Sentinel (azure) and Atlas (slate-blue) colour collision at 52px. Nova confirms: at thumbnail scale with the glow blur the two rims are indistinguishable. This is also a UX bug — the user cannot tell which drone is speaking when the rim-glow is the only colour signal. Atlas notes: no text label at that size means colour is the *only* differentiator. Nebula's fix (push Atlas to warm slate/violet, spread the hue wheel) is correct and should be treated as SEV high for design, not just brand.

---

## Broadcast Tension: Atlas Wants Icon Sync, Sentinel Wants No Storm

**Atlas R1 asked for:** broadcast a `settings` SSE event on every muted `/speak` so the menu-bar icon self-corrects.

**Sentinel R1 said:** fewer broadcasts — an echo-storm risk where every muted call triggers a full settings reload cascade.

**Resolution (concrete):** Don't broadcast on muted `/speak`. Instead, fire a **targeted `icon-state` SSE event** — a minimal `{ type: "icon-state", muted: true }` payload — once per `/speak` call *only when the muted state differs from what the daemon last confirmed to the client*. The daemon tracks `lastBroadcastMutedState`; if it matches the current state, no event fires. This gives the icon exactly the update it needs (a tiny dedicated event, not a full settings blob) and guarantees at most one event per actual state change regardless of call frequency. No echo-storm; no stale icon.

Implementation: `CaldwellHTTPServer.swift` — in the muted-return path of `/speak`, after returning `{"muted": true}`, check `lastBroadcastMutedState != currentMutedState` and if so, broadcast `icon-state` and update `lastBroadcastMutedState`. SSE clients read `icon-state` as a lightweight toggle; no settings reload triggered.

---

## Compound Bug: The Empty-Panel Failure (UX symptom + UI render gate)

This bug requires both lenses to fully describe:

**UX symptom (Atlas):** User set `showActiveAgents = OFF` deliberately. They expect the floating panel to stay out of their way. A drone speaks. The panel wakes, opens, and shows a blank rectangle for 5 seconds. The user has no frame for this — is the app broken? Is something loading? They have no label, no head, no caption, no affordance to close it. It violates the user's stated preference.

**UI render gate (Nova):** The render gate in `FloatingHeadsView` emits zero `FloatingDronePortraitView` items when `showActiveAgents = OFF` (participants list empty). The caption gate independently suppresses the bubble. But the `panelShouldBeVisible` computation upstream (DashboardViewModel) fires `true` on any `onPlaybackChanged(true)` event — it doesn't ask "would the panel actually render anything." The window frame, the NSPanel shadow, and the glow margin are all drawn regardless. The blank rectangle *is* the panel's chrome with nothing inside it.

**Unified fix:** In `DashboardViewModel.recomputePanelVisibility`, before setting `panelShouldBeVisible = true`, evaluate: `hasRenderableContent = !participants.isEmpty || captionWouldShow`. If false, skip the wake. One computed property, surgical gate, zero UI changes needed.

---

## Definitive De-duplicated Design Bug List (ordered by user impact)

| # | SEV | File | Title | Fix |
|---|-----|------|-------|-----|
| 1 | HIGH | `FloatingHeadsView.swift:270–287` / `DashboardViewModel` | Empty ghost panel: `showActiveAgents OFF` + drone speak opens blank window | Gate `panelShouldBeVisible` on `hasRenderableContent = !participants.isEmpty \|\| captionWouldShow` |
| 2 | HIGH | `FloatingHeadsView.swift:210–213` | All speakers share one home-arc lane — swap collision smear | Map per-`Participant.id` stable arc-index from `DroneRegistry.categories`; use in `homeOrbitOffset(for:)` |
| 3 | HIGH | `PopoverRootView.swift:57` | Default tab is History; first-run user never discovers drones | Keep History default; add empty-state: "Nothing yet — meet the team →" navigating to Roster |
| 4 | HIGH | `DroneRegistry.swift:77,85` | Sentinel/Atlas colour collision at 52px — rims indistinguishable | Push Atlas hue to warm slate/violet; spread six colours evenly around the wheel |
| 5 | MED | `FloatingHeadsView.swift:488–510` | Idle cluster repack is a hard positional jump, not an animated transition | `matchedGeometryEffect` per `Participant.id` or slot offset as `Animatable` driven by `withAnimation` |
| 6 | MED | `PortraitView.swift:46,107` | Blink state not reset on `droneName` change — blink fires over transitioning face | In `.onChange(of: droneName)`, also reset `blinkStart = -1` and defer `nextBlinkAt` by swap-window (~0.5s) |
| 7 | MED | `FloatingPanelController.swift:180` / `SubtitleBubbleView.swift:41` | Bubble `maxWidth` == `panelWidth` — rim-glow clips at panel edge | Reduce `maxWidth` to `panelWidth - 2 * glowMargin` (216pt) or widen panel to 280pt |
| 8 | MED | `FloatingHeadsView.swift:470–477` | Arc→cluster mode-switch has no animated intermediary — orbit drones snap | Drive `slotOffset` through `withAnimation(.spring(response:0.5))` when clearing speaker in `scheduleReturnToSwarm` |
| 9 | MED | `SettingsView.swift:175–203` | Disabled toggles grey out silently — no explanation of `floatingHeadEnabled` dependency | Add conditional caption: "Requires floating head — enable above." when `floatingHeadEnabled == false` |
| 10 | MED | `AppDelegate.swift:184–197` | Panel hide animation ignores Reduce Motion — 900ms fade plays regardless | Check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`; if true, snap `alphaValue = 0`, skip animation |
| 11 | LOW | `FloatingHeadsView.swift:225` | Queue overflow: >5 items, 6th head silently disappears, no indicator | Add `"+N"` badge at last thumbnail slot when overflow > 5 |

---

— *Atlas. Senior UX, ex-Linear. The ghost panel is the one that'll get a 1-star review.*
— *Nova. Craft lens, ex-Arc. Fix the arc-lane and the repack snap — those are the headline mechanic and the swarm polish. Right now neither earns the pixel.*
