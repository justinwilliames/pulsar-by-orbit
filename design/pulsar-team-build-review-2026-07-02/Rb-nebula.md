# Rb-Nebula — Visual Legibility & Brand Coherence Review
**Reviewer:** Nebula (visual/brand lens)
**Build:** pulsar-fixes @ 346c221
**Date:** 2026-07-02

---

## 1. Rim-colour distinctness at 52px

All 8 entries (7 drones + Pulsar) rendered as 52px swatches and evaluated via CIE76 delta-E. Threshold: ≥30 = OK, 20–30 = RISK, <20 = CONFUSABLE.

| Pair | Hex A | Hex B | dE76 | Verdict |
|---|---|---|---|---|
| **pulsar vs atlas** | `#818CF8` | `#9E73D9` | **17.0** | **CONFUSABLE** |
| nebula vs atlas | `#E85CD1` | `#9E73D9` | 32.6 | OK (borderline) |
| sentinel vs unknown | `#6BB8EB` | `#949499` | 33.5 | OK (borderline) |
| sentinel vs echo | `#6BB8EB` | `#2EBFB8` | 38.2 | OK |
| echo vs unknown | `#2EBFB8` | `#949499` | 40.3 | OK |

**Only one genuinely confusable pair: pulsar (#818CF8 periwinkle-indigo) vs atlas (#9E73D9 warm violet). dE76=17 — well below threshold.** At 52px these two bleed into each other; a user glancing at an orbiting swarm mid-swap will not reliably tell them apart.

The orchestrator's reported "atlas/voyager confusion mid-swap" is not a colour issue (amber vs violet dE=113 — impossible to confuse). This is likely a portrait-crossfade timing artefact, not a hue problem.

Atlas portrait is clearly distinct from voyager's at small size — dark-ish humanoid vs rugged-goggled figure, different silhouettes. Portrait level: **OK**.

---

## 2. The `unknown` drone

**Critical finding: `unknown` has NO portrait files.**

`unknown-mouth-0.png` through `-mouth-4.png` and `unknown-blink.png` do not exist. When `FloatingDronePortraitView` renders `droneName: "unknown"`, `PortraitView.loadFrames()` returns an empty array and falls back to the **monogram** view — a letter from `voiceName`, which is `"unknown"`. So the unknown drone renders as a grey squircle with the letter **"u"** in it, not a face.

DroneRegistry comments say it "shares Daniel's voice so the portrait server falls back to Pulsar's portrait frames." This is **incorrect** — the portrait resolution path uses `droneName`, not voice. There is no voice-to-portrait fallback; the frame loader strictly uses the category string. The `?` badge helps, but a lower-case initial "u" is not a clear "generic agent" signal.

**Verdict:** Unknown reads as broken/missing, not deliberate. Fix: either (a) add portrait frames for `unknown` (even a simple generic silhouette), or (b) map `"unknown"` droneName to `"pulsar"` explicitly in `loadFrames()`.

---

## 3. Visual-system coherence

All 7 bespoke portrait frames share coherent art direction: sci-fi robot aesthetic, dark space background, head-and-shoulders crop, consistent lighting from above-left, similar scale and framing. The family reads as one cast. No outlier.

Echo and Atlas are the most visually similar portraits at 52px (both darker tones, similar silhouette class), but their rim colours are distinct enough (teal vs violet, dE=86) to differentiate.

---

## 4. Leftover user-visible "Caldwell" strings

`Info.plist`: `CFBundleDisplayName = "Pulsar"`, `CFBundleName = "Pulsar"`, `CFBundleIdentifier = team.yourorbit.Pulsar` — **all clean**.

Remaining "Caldwell" is in internal class names only: `CaldwellConfig`, `CaldwellHTTPServer`, `CaldwellDashboardApp`, `Package.swift` target name. None user-visible. Two inline comments in `AudioQueueActor.swift` ("so Caldwell never fires…", "hear Caldwell and only the premium voice failed") — **internal only, not shipped UI strings**. Safe to leave or rename at leisure.

---

## Summary findings (for orchestrator)

```
[SEV1] colour — pulsar vs atlas RIM CONFUSABLE — dE76=17 (#818CF8 vs #9E73D9); recommend shifting atlas to a warmer purple with more red (try #B060E0 ≈ dE~35 from pulsar) or deepening atlas saturation
[SEV2] unknown drone — NO PORTRAIT FILES — falls back to monogram "u", reads broken not deliberate; map droneName "unknown"→"pulsar" in PortraitView.loadFrames or add generic portrait frames
[SEV3] nebula/atlas borderline — dE76=32.6 (#E85CD1 vs #9E73D9); acceptable but if atlas shifts redder per SEV1 fix, this gap widens automatically — re-check after
[INFO] "Caldwell" in user-visible strings: NONE — plist, bundle ID, display name all say "Pulsar"; internal class names only
[INFO] Portrait family coherence: PASS — all 7 drones share one art system, no outlier
[INFO] atlas/voyager mid-swap confusion: NOT a colour issue (dE=113); likely portrait-crossfade timing bug, out of scope for this lens
```
