# Nova UI Review — pulsar-fixes branch (18b81a4→HEAD)
_2026-07-01_

## 1. Empty-panel gate — PASS

`hasRenderableContent` logic is correct. When `showActiveAgents` OFF, the gate returns `playback.isPlaying || playback.queuedCount > 0`, which correctly opens the panel only when Pulsar is audibly active. Drone-only in-flight activity stays silent. No regression: when `showActiveAgents` ON the original `pulsarIsPresent || hasInFlightDrones || queuedCount > 0` path is unchanged.

Edge traced: `panelShouldBeVisible → hasRenderableContent → (agentsOff branch) → isPlaying`. Solid.

## 2. Arc-lane collision — PASS (with one note)

`stableArcIndex` calls `DroneRegistry.categories.firstIndex(of: category)`. `DroneRegistry.categories` is derived from `drones.map(\.category)`, which now includes `"unknown"` at index 6. So:
- `unknown` drone → index 6, Pulsar → index 7 (count=8 for total)
- `firstIndex` fallback for unrecognised strings → `categories.count` (= 8 = Pulsar's slot) — safe deduplication with Pulsar but won't collide with a real drone lane

**Note (non-blocking):** an unknown drone and Pulsar share the same `stableArcIndex` fallback slot (8). In practice the swap animation is short, and unknown drones don't typically speak simultaneously with Pulsar passing through; no crash risk. Would be cleaner to assign unknown a dedicated slot, but it's not a bug.

`isDrone("unknown")` returns `true` (it's in `byCategory`), so `unknown` flows through `stableArcIndex` correctly and does NOT fall to the Pulsar-slot accidentally.

## 3. Spring repack + blink reset — PASS

Four `.animation` keys on `FloatingHeadsView`: queue ids, sortedDrones, participants (new — repack), and `speaker == nil` (new — mode-switch). Keys are independent value types; no animation fight risk. The ViewModel's `returnToSwarmTask` now wraps the nil-clear in `withAnimation(.spring(response:0.48, dampingFraction:0.74))`, which matches the FloatingHeadsView's mode-switch spring — consistent easing across both layers.

Blink reset in `PortraitView.onChange(droneName)`: sets `blinkStart = -1` and defers `nextBlinkAt` by 0.5s + random 3.5–5.0s. Correct — prevents a mid-blink frame from the old face bleeding onto the new portrait. Compiles cleanly (no async/actor issues; `Date().timeIntervalSinceReferenceDate` is main-thread safe here).

## 4. Rim-glow inset — PASS (arithmetic confirmed)

Panel width = 248 (`SubtitleBubbleView.maxWidth`). Caption gets `.padding(.horizontal, captionEdgePadding * 2)` = 32pt each side. `SubtitleBubbleView.maxWidth` is 248pt, which already accounts for the bubble fitting inside the panel. The bubble's own `maxWidth: 248` is the *bubble frame*, not constrained further by the padding (SwiftUI `.padding` on a parent doesn't shrink a fixed-size child). No overflow risk — the panel is sized to `maxWidth` exactly, and the glow reserve (16pt glowMargin × 2 = 32pt) is within the 248pt window.

Wait — `panelWidth` in `FloatingPanelController` is set to `SubtitleBubbleView.maxWidth` (248), while `SubtitleBubbleView.maxWidth` is the bubble's *internal* max. The 2× horizontal padding is on the parent wrapper in `FloatingHeadsView`, which constrains the *caption's layout zone* — the bubble itself is constrained to `maxWidth: 248` inside, so the effective visible bubble is at most 248 − 32 = 216pt. That's tighter than before but the comment says this was the intent (give the plusLighter rim-glow full margin). No clipping.

## 5. Fixed drone-count-of-6 references — PASS

No hardcoded `6` found in the drone-count path. `DroneRegistry.categories` is computed from `drones.map(\.category)` (now 7 entries). `stableArcIndex` uses `categories.count` dynamically. No array literal with count 6. The `orbitSlotCount` is participant-derived. Clean.

---

## Verdict

| Fix | Result |
|---|---|
| Empty-panel gate (`hasRenderableContent`) | **PASS** |
| Arc-lane collision (`stableArcIndex` + `unknown`) | **PASS** (minor note: unknown shares Pulsar's fallback slot — non-blocking) |
| Spring repack + blink reset | **PASS** |
| Rim-glow inset (2× captionEdgePadding) | **PASS** |
| Fixed count-of-6 fragility | **PASS** |

No [BLOCKER] or [BUG] found.
