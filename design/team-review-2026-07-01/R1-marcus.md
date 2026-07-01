# R1 · Marcus Holm — UI Craft / Visual Hierarchy
**Feature:** Pulsar Drones — trade-places animation, name-card pill, subtitle bubble, orbit layout, colour palette

---

## Verdict

The bones are correct — true place-swap, colour theming, typewriter reveal — but the swap animation is mechanically functional rather than *felt*, the name-card pill is the visual equivalent of a sticky label, and the orbit arc is one drone away from a collision. Premium is 3–4 targeted number changes, not a rewrite.

---

## Top 3 Findings

### 1. The swap spring is too stiff — it reads "slide" not "breath"

`FloatingHeadsView.swift` lines 102–103: two separate `.spring(response: 0.5, dampingFraction: 0.78)` and `(.spring(response: 0.42, dampingFraction: 0.72))` animate the swap. The damping fractions are both in the 0.7–0.8 range — that's the "UI toggle" zone: decisive but underdramatic. For a theatrical **character-swap** between premium 3D robots, you want the arriving occupant to overshoot slightly and settle, not just slide to position. Target: `response: 0.38, dampingFraction: 0.62` for `activeDroneCategory`. The departing Pulsar should feel like it's been bumped aside — `response: 0.55, dampingFraction: 0.74` lets it ease out slower, creating a stagger. Right now both springs are nearly identical in feel; there's no leading/following relationship, so the swap reads as two simultaneous slides.

The `.transition(.opacity.combined(with: .scale(scale: 0.85)))` on `centreOccupant` (line 124) is the other offender: 0.85 scale-from is too subtle to read as a dimensional pop. A drone arriving at centre stage should come in at 0.72 scale and punch through 1.0 — make it feel like the character stepped forward. Departing should exit at 0.9 (shrinking slightly, not disappearing).

### 2. Name-card pill is typographically cheap

`droneNameCard` in `FloatingHeadsView.swift` line 238–254: `9pt .heavy .rounded` tracked at `0.8` in `ALL CAPS`. The 9pt floor is the problem — at macOS display densities this is borderline legible, and `.heavy` at that size fills in, losing the letter spacing. The result is a blob of reversed-out text, not a crisp identity chip. Fix: `10pt .semibold .rounded`, tracking `1.2`, `foregroundStyle(.white.opacity(0.95))`. The `Capsule().stroke(color, lineWidth: 1).blur(radius: 1.5)` inner border is doing nothing visible — the blur dissolves the 1pt line entirely. Replace with `.strokeBorder(color.opacity(0.6), lineWidth: 1)` (no blur) or drop it. The `shadow(color: color.opacity(0.5), radius: 4)` is the only legible affordance and should scale up to `radius: 8` to match the ambient glow register of the bubble.

The `offset(y: -14)` placement puts the pill floating mid-air between bubble and head without visual anchoring. Shift to `offset(y: -10)` and add a `padding(.bottom, 4)` to the bubble's tail gap so the pill reads as attached to the bubble crown, not free-floating.

### 3. Sentinel and Echo are neighbours in hue space

`DroneRegistry.swift` lines 52–53: Sentinel cyan `(0.35, 0.78, 0.88)` and Echo teal `(0.25, 0.82, 0.78)` are 15° apart in HSB. At 40pt thumbnail size in orbit, these are **the same colour** under casual glance — especially with a blurred glow halo eating the hue edges. Atlas slate `(0.53, 0.58, 0.66)` is also too desaturated to glow distinctively; its `radius: 16` glow in `FloatingDronePortraitView` line 57 will appear almost grey. Concrete fix: push Echo to `(0.18, 0.75, 0.72)` — a deeper teal closer to blue-green — and desaturate Sentinel slightly to `(0.42, 0.72, 0.92)` to increase their perceptual distance. Atlas needs a saturation boost: `(0.50, 0.55, 0.80)` reads as steel-blue rather than muddy grey.

---

## Single Highest-Impact Fix

**The swap spring stagger (Finding 1).** It's the centrepiece interaction — every other design detail is in service of making that moment land. Split the two springs so the arriving drone leads with `response: 0.38, dampingFraction: 0.62` and departing Pulsar follows with `response: 0.55, dampingFraction: 0.74`, and push the entry `.scale` down to 0.72. That alone lifts this from "toggling views" to "characters trading the spotlight." Everything else is polish on top of a working mechanic; this is the mechanic.

---

## One Question for Another Lens

For the **motion/animation reviewer**: the `TimelineView(.animation)` bob loop in `FloatingDronePortraitView` runs at display refresh for every orbiting drone simultaneously. At 6 drones + Pulsar, that's 7 concurrent animation timelines. Is there a measurable CPU/power budget concern here, and should the idle drones' bob be throttled (e.g. `.animation(schedule: .periodic(interval: 0.05))`) while the active speaker runs at full rate?
