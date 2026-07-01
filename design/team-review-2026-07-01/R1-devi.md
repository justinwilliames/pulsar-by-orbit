# R1 — Devi Sharma · Growth / Product Marketer

> Who is this for and what changes after they use it?

---

## Verdict

**Shareable — but only if the swap is the story, and right now the story is buried.**

The mechanic is genuinely novel: a named, coloured robot steps into the spotlight when it speaks, Pulsar slides over, the bubble glows their colour. That's a "wait, did you see that?" moment. The problem is nothing tells the *user* what they're watching. A crew of robots appearing silently around Pulsar without any onboarding narrative is a curiosity, not a conversation starter.

---

## Top 3 Findings

**1. The name card is 9pt uppercase — it's the only story hook and it's unreadable at a glance.**

`droneNameCard` in `FloatingHeadsView.swift` renders the active drone's name at `.font(.system(size: 9, weight: .heavy, design: .rounded))` with `.tracking(0.8)`, offset -14pt above the caption bubble. At that size and placement, it's invisible to anyone who doesn't know to look for it. This is the *one* thing that teaches "oh, that's Sentinel — the reviewer" — the single character beat that makes drones feel like a cast, not a palette swap. If you can't read the name, drones are just coloured blobs. The fix is immediate: bump to 11pt, increase the pill's horizontal padding to 12pt, and move it -20pt so it clears the bubble rim cleanly. This is a two-line code change with outsized narrative payoff.

**2. The "trade places" swap has no verbal signal — it's visual-only.**

The place-swap animation (`.spring(response: 0.5, dampingFraction: 0.72)` on `activeDroneCategory`) is smooth but silent. There's no ambient sound, no distinctive entry tone, no line of speech that says "Sentinel here." A dev watching this for the first time won't know a swap happened unless they're staring at the widget. The clip-worthy moment — the one told over coffee — is hearing a different voice, seeing a different glow, AND knowing *why*. Right now you get the first two; the third requires the user to already understand the system. A one-word verbal handoff ("Sentinel.") on drone swap-in would complete the loop without adding engineering cost.

**3. Six drones in orbit with a 140° arc reads as clutter before it reads as a crew.**

`orbitAngle` distributes drones between `arcStart: 20°` and `arcEnd: 160°` — that's a 140° bottom arc at `orbitRadius: 82pt` around a 240pt head zone. At 5–6 drones, thumbnails at 40pt are ~48pt apart edge-to-edge. With individual `bobX/bobY` offsets (±2pt, ±1.5pt), they'll clip each other during animation. More importantly: 6 simultaneously visible drones is a screenshotting nightmare — the composition looks busy, not premium. The shareable frame is 1–2 drones in orbit max. The code already limits `queued.prefix(5)` for queue bubbles; add a display cap of 3 for in-flight drones (`sortedDrones.prefix(3)`) and favour the most recently activated. The least-recently-used ones can be represented by a count badge on the last visible drone.

---

## Single Highest-Impact Fix

**Make the name card legible — 11pt, 12pt h-padding, -20pt offset.**

In `FloatingHeadsView.swift`, `droneNameCard`: change `size: 9` → `size: 11`, `.padding(.horizontal, 8)` → `.padding(.horizontal, 12)`, `.offset(y: -14)` → `.offset(y: -20)`. Three number changes. This is the difference between "some coloured robot appeared" and "oh, that was Nova — the builder." Everything else about shareability hangs on the user being able to identify who just spoke.

---

## One Question for Another Lens

**Animation/interaction lens:** does the swap feel like a *handoff* or a *collision*? The spring values for centre↔orbit are slightly different (`0.5/0.72` vs `0.5/0.78`) — is that intentional choreography, or did the two springs drift independently? Asking because a matched spring on both sides of the swap would make the trade feel like a single gesture, not two separate reactions.
