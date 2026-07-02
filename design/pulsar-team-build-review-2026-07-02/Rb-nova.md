# Nova — FloatingHeadsView Bug Review (2026-07-02)

Branch: `pulsar-fixes` @ HEAD 346c221 | Diff base: 6f3ea28 | 269 lines changed

---

## Bugs Found

### [SEV-HIGH] FloatingHeadsView.swift:580–613 — Every participant runs 60Hz portrait forever
**ParticipantSlotView** layers **both** `FloatingPortraitView` and `FloatingDronePortraitView` in a ZStack and crossfades by opacity. `FloatingPortraitView` runs a 60Hz `TimelineView(.animation)` with aura glow, pulse ripples, rim glow, and a bob — continuously, even when `opacity = 0` and the participant is orbiting. At 6 participants: 6 × 60Hz portrait + 6 × 20Hz thumbnail = all running full-time.

**Fix:** gate the portrait `TimelineView` on `isCentre`. When orbiting, render a static placeholder or suspend the animation (e.g. `AnimationTimelineSchedule(minimumInterval: 1, paused: !isCentre)`). The thumbnail already correctly runs at 20Hz.

---

### [SEV-MED] FloatingHeadsView.swift:585–586 — Wrong voiceLabel on non-centre portraits
`ParticipantSlotView` passes `speaker?.voiceLabel ?? "Pulsar"` to **every** participant's `FloatingPortraitView.voiceName`, including orbiting ones. If an orbiting participant falls back to the monogram (missing frame assets), it shows the **active speaker's** initial, not its own. The correct value is `participant.category ?? "Pulsar"`. Low blast-radius in practice but a real correctness bug.

**Fix:** `voiceName: participant.category?.capitalized ?? "Pulsar"` for the orbit-layer portrait; only the centre needs `speaker?.voiceLabel`.

---

### [SEV-MED] FloatingHeadsView.swift:161–174 — Reduce Motion not honored for slot glides
The ZStack `.animation()` modifiers that drive the slot glide (scale + offset) are not gated on `reduceMotion`. With macOS Reduce Motion enabled, participants still slide/spring between slots. Only the drone drift freezes (correctly — `FloatingDronePortraitView` gates its schedule on `reduceMotion`).

**Fix:** wrap each `.animation()` in `reduceMotion ? .easeInOut(duration: 0) : <spring>` or use `.animation(reduceMotion ? nil : .spring(...), value: ...)`.

---

### [SEV-MED] FloatingDronePortraitView.swift:55 — Bob phase snaps when participant moves centre→orbit
`FloatingDronePortraitView` computes drift phase as `Double(index) * 1.7`. Inside `ParticipantSlotView`, the `index` passed is `participant.orbitIndex`, which is hardcoded `0` when `isCentre = true`. When the participant moves to orbit at e.g. index 2, phase jumps from `0` to `3.4` at the moment the thumbnail fades in — a visible directional snap on the fade-in.

**Fix:** derive phase from a stable per-category hash (`category.hashValue % 7`) rather than the current orbitIndex.

---

### [SEV-LOW] headZone panelHasContent = true + showAgents = false + Pulsar silent = empty panel
When `showAgents = false`, `pulsarIsPresent = true` (drones in flight), but Pulsar isn't speaking: `participants = []` (Pulsar orbit gated on `showAgents`, no drone heads rendered). `panelHasContent = true` keeps the panel open, but the head zone renders nothing. Caption could appear with no head. By design (voice-only mode) but visually broken for the captionless case.

**Fix / consider:** when `showAgents = false && participants.isEmpty`, suppress `panelHasContent` or emit a minimal silent Pulsar indicator.

---

## Cleared / No Bug

- **Ghost duplicate concern:** The old two-branch `participantView` (insert/remove transitions) causing "two Echoes" is correctly eliminated. `ParticipantSlotView` with stable `.id(p.id)` prevents ForEach from tearing down + rebuilding on swap. Ghost bug: fixed.
- **Pulsar arc collision:** Pulsar gets `orbitIndex: 0` prepended before drones, so indices enumerate cleanly with no collisions.
- **hasInFlightDrones gate logic:** The `!viewModel.hasInFlightDrones` gate on `queuedThumbnails` correctly suppresses the background layer when the swarm is live. `dedupedQueuedItems` correctly deduplicates against `participantCharacterKeys`. No spurious duplicates.
- **Opacity cross-fade animation:** The ZStack springs keyed on `activeDroneCategory` and `speaker == nil` carry the opacity change through SwiftUI's transaction — cross-fade is animated, not a snap.
- **ForEach id collision:** No duplicate ids. Participant ids are stable strings ("pulsar" or category name), unique by design.

---

## Verdict

The **ghost duplicate fix is solid** — the core swap rework achieves its goal. Three medium bugs need fixing before shipping: the 60Hz always-on portrait rendering is a real perf problem at 6+ drones, the Reduce Motion bypass is an accessibility regression, and the bob phase snap is visible. The wrong voiceLabel is a latent correctness issue. None are regressions introduced by the swap rework (the perf issue is the structural cost of the layered approach).
