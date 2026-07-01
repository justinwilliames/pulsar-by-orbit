# Round 1 — Yuki Tanaka, Senior UX Designer

## Verdict

The swap mechanic earns its complexity — a speaking drone genuinely taking the throne is the right interaction metaphor — but right now the system asks a developer to read 6 colour-coded faces, a name card, a coloured caption rim, AND a swapping layout simultaneously, and the answer to "who is doing what" is split across all four. Fix the name card and you halve the load.

---

## Top 3 findings

### 1. The name card placement buries the most useful signal (FloatingHeadsView.swift:235–254)

The name-card pill (`category.uppercased()`) is anchored to `.top` of the caption bubble with a -14pt offset — meaning it floats BELOW the head, at the seam between portrait and caption. At that position it competes visually with the tail of the speech bubble and the rim glow at the same moment the user's eye is tracking the centre portrait swap. The category name ("VOYAGER") is the primary answer to "what is this agent?" but it's the last thing the eye lands on. It should be pinned directly to the centre portrait (overlay on the head zone, not the caption zone), positioned BELOW the squircle with ~6pt gap — the same axis the user is already looking at. This is a layout change in `droneNameCard` and the `captionZone` overlay site (line 206).

### 2. Colour alone distinguishes 6 agents with no shape or icon fallback (DroneRegistry.swift)

Sentinel (cyan `0.35/0.78/0.88`) and Echo (teal `0.25/0.82/0.78`) are adjacent on the hue wheel and will be indistinguishable under any kind of ambient tint, dark glass, or mild colour vision deficiency. The orbit itself uses only colour to identity each drone — the squircle glow, the rim stroke, the name-card background. There is no shape, badge, or letter mark fallback in the idle orbit thumbnails (PortraitView uses a monogram letter only when the art frames are missing entirely). Minimum fix: the role string is already available in `DroneRegistry.Drone` — a one-letter role badge (`E`, `R`, `B`, `A`, `W`, `G`) rendered in the squircle corner at thumbnail size gives a redundant identity cue and costs nothing at render time. Implement in `FloatingDronePortraitView` body when `thumbnailSize` is ≤ 44pt.

### 3. Full-screen motion at 60Hz during idle work is an attention thief (QueueBubbleView.swift:347–377, PortraitView.swift)

`TimelineView(.animation)` runs every frame on every in-flight drone simultaneously — each one bobbing on independent sine/cosine offsets. During a long background task where the developer is actively reading code, up to 6 portraits are animating continuously in their peripheral vision. macOS accessibility has the "Reduce Motion" setting precisely for this. None of the animation calls check `accessibilityReduceMotion`. The bob should freeze (offset `0, 0`) and the blink should persist (no timer) when the user has Reduce Motion on. This is a `@Environment(\.accessibilityReduceMotion)` check at the top of each TimelineView body.

---

## Highest-impact fix

**Move the name card onto the head portrait, not the caption bubble.**

In `FloatingHeadsView`, relocate the `droneNameCard` overlay from `SubtitleBubbleView`'s `.overlay(alignment: .top)` wrapper (line 206) to an `.overlay(alignment: .bottom)` on the `centreOccupant` view (line 114–124). Position it with a fixed `offset(y: +14)` below the squircle. The user's eye is already on the face; the label appears at the natural reading position immediately below it, role and name co-located with the avatar. This eliminates the cross-region eye scan (face → seam → label) that currently fragments the "who is speaking" read, and the fix is 8 lines of movement with no new components.

---

## One question for another lens

The place-swap uses `.opacity.combined(with: .scale(0.85))` as the transition — same in and out for both characters simultaneously. At what point does the crossfade feel like a crash rather than a handoff? What's the right timing relationship between the departing portrait's exit and the arriving one's entrance — overlap, sequential, or a hard cut at the midpoint?
