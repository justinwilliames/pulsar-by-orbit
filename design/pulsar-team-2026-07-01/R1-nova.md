# R1-Nova — UI Craft / Rendering / Animation Review
**Pulsar Drones · pulsar-drones branch · 2026-07-01**

---

## Verdict

The core swap mechanic is architecturally sound but four concrete rendering bugs — a hard positional pop on swarm repack, a single shared home-arc lane causing an insertion flash, a blink window that can fire mid-transition, and a `SpeechBubbleShape` tail that hard-clips against `panelWidth` at narrow window positions — prevent this from reading as premium. Fix the pop and the home-arc bug first; the rest are polish.

---

## Bug List

---

### [SEV high] FloatingHeadsView.swift:210–213 — All departing/arriving speakers share a single hard-coded home-arc lane

**WHY:** `homeOrbitOffset(for:)` always uses `index: 0` regardless of how many orbit slots are live. Every swap — arrival and departure — animates through the same point (slot 0 at the current count). If two speakers swap in rapid succession, the incoming drone and the outgoing Pulsar both travel to/from the same pixel: they cross each other on identical trajectories, producing a visual smear/collision flash rather than a pass-the-baton arc. The "matched arc" comment in the code promises they pass each other; the implementation makes them collide.

**FIX:** Compute a stable per-`Participant.id` home-arc index (map the participant's canonical category order from `DroneRegistry.categories`) so each speaker has its own departure lane, then use that in `homeOrbitOffset(for:)`.

---

### [SEV high] FloatingHeadsView.swift:488–510 — Idle cluster repack is a hard discontinuous jump, not an animated transition

**WHY:** `symmetricClusterOffsets(_:)` returns absolute CGSize offsets keyed to slot position in `orbitKeys`. When a drone joins or leaves the swarm while no speaker holds centre, every drone's computed slot offset changes — the orbiting drones jump to their new geometric positions rather than springing there. SwiftUI's `.animation` modifier on `sortedDrones.map(\.id)` (line 149) keys on membership, not individual slot positions, so the per-drone `offset()` modifier doesn't participate in the animation. Adding or removing a single drone re-packs the whole pod and every head snaps.

**FIX:** Use `matchedGeometryEffect` (with a `Namespace` keyed to `Participant.id`) or give each `FloatingDronePortraitView` its slot offset as an `Animatable` property driven by `withAnimation` at the parent level — not just a membership-keyed `.animation`.

---

### [SEV med] PortraitView.swift:46, 107 — `droneName` change reloads frames but does NOT reset blink state; a blink can fire over a transitioning face

**WHY:** The `.onChange(of: droneName)` handler at line 106 replaces `frames` and `blinkFrame`. It does NOT reset `blinkStart` or `nextBlinkAt`. If a blink is in flight when the drone name flips (Pulsar → Voyager during a swap), the blink overlay at its current opacity renders over the incoming drone's frame 0 before the eye/brow art has settled. At 120ms blink duration and ~400ms swap animation this is a visible mid-transition eye-close artefact on the new face. Similarly, if `blinkStart < 0` but `t >= nextBlinkAt` at the moment of the transition, the very next timeline tick fires a blink on a face that hasn't finished arriving.

**FIX:** In the `.onChange(of: droneName)` block, also set `blinkStart = -1` and `nextBlinkAt = t + Double.random(in: 1.5...2.5)` to clear any in-flight blink and delay the next one past the swap animation window (~0.5s).

---

### [SEV med] FloatingPanelController.swift:180 + SubtitleBubbleView.swift:41 — Panel width (248pt) equals bubble `maxWidth` (248pt) with zero safe margin at horizontal edges

**WHY:** `FloatingPanelController.panelWidth` is set to `SubtitleBubbleView.maxWidth` (248pt). The bubble applies horizontal padding (`captionEdgePadding = glowMargin = 16pt`) from FloatingHeadsView, but `SubtitleBubbleView.maxWidth` is `248pt` — the same as the panel. The `.frame(maxWidth: Self.maxWidth)` on the bubble's `content()` view (line 112 of SubtitleBubbleView) plus the `16pt` horizontal padding on the outer container means the `SpeechBubbleShape` fill can reach exactly to the panel edge. The outer glow (`rimGlow`, 4–6pt blur, `plusLighter`) then bleeds past the NSPanel's `NSRect` and gets hard-clipped into a rectangle on either side — visible as a squared-off glow edge when the panel is near any screen edge. `glowMargin` (16pt) is correctly included as vertical padding but the `maxWidth` reservation doesn't account for horizontal glow on both sides (needs 2× glowMargin).

**FIX:** Either reduce `SubtitleBubbleView.maxWidth` to `panelWidth - (2 * glowMargin)` = 216pt, or widen `panelWidth` to `maxWidth + 2 * glowMargin` = 280pt. The panel-width constant in `FloatingPanelController` needs to match.

---

### [SEV med] FloatingHeadsView.swift:470–477 — Swarm transitions between arc-mode and cluster-mode have no animated intermediary; mode-switch snaps

**WHY:** `slotOffset(index:total:)` returns arc positions when `speaker != nil` and cluster positions when `speaker == nil`. The moment the speaker slot clears (returnToSwarm fires, `currentVoice = nil`), every orbit drone's base offset snaps from its arc angle to its cluster grid position. The `.animation` on `activeDroneCategory` (line 153) animates the centre occupant's departure, but the orbit drones' `slotOffset` call has no animated transition between modes — the geometric value just changes. Every orbiting head pops from "arc above the hub" to "symmetric pod around the centre".

**FIX:** Expose `slotOffset` as an `@State`-driven animated value (or use `withAnimation(.spring(response:0.5))` when clearing the speaker in `scheduleReturnToSwarm`) so orbit drones spring to their cluster positions rather than jumping.

---

### [SEV low] FloatingPortraitView.swift:181 — `pulseRipples` Canvas frame (portraitSize + 110) can overflow headZoneHeight at full amplitude

**WHY:** The Canvas frame is `portraitSize + 110 = 230pt` (120 + 110). `headZoneHeight` is `240pt` but the head zone is centred in it, placing the portrait at `y ≈ 0` (centre of 240pt zone). The portrait's bottom sits at `y = 60pt` from zone centre; the ripple Canvas at `y_half = 115pt`. At full amplitude the ripple half-extent is `baseHalf + 2 + 1.0 * (16 + 14) = 92pt` plus the 7pt Canvas blur = 99pt, which fits. But the glow aura (`auraGlow` with `blur(radius: 16)` on a `swell + 18` frame) at peak is `swell ≈ 143pt` → frame = `161pt`, blur tail ≈ 45pt → half-extent ≈ 125pt. With the portrait centred at the head zone's mid-height, this comfortably clears the 120pt half-extent of the zone — but only barely. One `orbitYOffset` (-8pt) shift means the portrait sits 8pt above centre, so the top glow tail has only ~112pt clearance. Not a hard clip in normal use, but the maths say the top edge of the aura can just touch the panel edge at peak amplitude on long utterances.

**FIX:** Either increase `headZoneHeight` by 16pt or reduce `auraGlow`'s outer frame by 8pt (`swell + 10` instead of `swell + 18`) — tiny change, no visible difference, guaranteed margin.

---

### [SEV low] FloatingHeadsView.swift:225 — `queuedThumbnails` uses `.prefix(5)` but there is no "+N overflow" indicator for queues > 5

**WHY:** Lines 225–239 silently show only the first 5 queued items and drop the rest. If 6+ items queue, the 6th head just disappears with no visual feedback. The user can see voices playing but can't know how many are pending, breaking the "live team visible" promise. There is no `+N` label, no overflow badge, no visual indicator.

**FIX:** Add a small "+N" overlay badge at the last visible thumbnail position when `viewModel.queueItems.filter { !$0.isPlaying }.count > 5`. A `Text("+\(overflow)")` at `thumbnailSize * 0.6` pinned to the last slot is sufficient.

---

## Highest-Priority Fix

**[SEV high] All speakers share a single home-arc lane** (FloatingHeadsView.swift:210–213). The "pass the baton" swap is the headline interaction — the visual proof that multiple drones are distinct characters. When they smear through the same pixel on every transition, the mechanic reads as broken, not choreographed. Fix this before anything else ships.

---

## Question for Another Drone (Sentinel — Engineering/QA lens)

The `returnToSwarm` task (DashboardViewModel.swift:286–296) clears `currentVoice`, `currentText`, and `currentAgentCategory` after 5 seconds. But AppDelegate's `scheduleHide` also fires after `tailAfterIdle` (5s) and calls `hidePanel`, which clears the same three fields in its completion handler. Both timers start when audio ends. In a swarm scenario, `returnToSwarm` fires at t+5s; but `scheduleHide` is also queued from `recomputePanelVisibility` when it next re-evaluates. Is there a guaranteed ordering, or does `hidePanel`'s fade completion (at t+5s+0.9s) race with a new line arriving and re-showing the panel, writing `currentVoice` mid-clear?

---

*Nova — green drone, builder lens. Does it earn the pixel? Some of it doesn't, yet.*
