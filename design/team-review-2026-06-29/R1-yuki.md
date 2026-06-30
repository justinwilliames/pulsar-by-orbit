# R1 — Yuki Tanaka, Senior UX Designer

**Date:** 2026-06-29  
**Round:** 1 (solo diagnosis)

---

## Verdict

The core loop works — app up, hook fires, voice speaks — but the Settings view is doing the IA job of three different products at once, and the Mac voice path is so invisible that users will burn credits for a week before discovering it exists.

---

## Top 3 Findings

### 1. The voice engine has no home — and that's the highest-risk gap right now

The proposed Mac vs ElevenLabs engine toggle doesn't exist yet in the UI. That's fine — but what *does* exist sets a problematic expectation: the Settings view leads with "ELEVENLABS API KEY" as its first and heaviest element, framing ElevenLabs as the *product* rather than one engine option among two. When Mac Enhanced voices are added, dropping a second toggle below an API key field will feel like an afterthought, not a peer choice. The information architecture needs to shift before the toggle lands, not after.

The download discoverability problem compounds this. You can't ship the Mac voice path with a link to System Settings buried in a tooltip or README. The user's moment of doubt — "why isn't it speaking?" after their credits run out — needs a recovery path inside the app. Right now there's no in-app voice-engine status, no "Mac voice: Daniel Enhanced not installed — here's how" affordance, and nothing connecting the ElevenLabs exhausted state (which the UI does surface, correctly) to the alternative. A user who hits the exhausted banner has nowhere to go from within the app.

### 2. The tab structure hides the one thing users need mid-session: mute

Mute is the highest-frequency action in a live session. It's correctly surfaced in the header — good. But it's a capsule badge, not a primary button; it's styled identically whether the state is Live or Muted (same capsule, same weight, colour-coded but not shape-differentiated); and the tooltip text reads like settings copy, not an action affordance. In a quick glance from a meeting, you shouldn't have to read anything to know if you're muted. The icon swap (speaker vs speaker.slash) is correct but the label "Live" / "Muted" next to it is redundant with the icon and wastes the real estate that should communicate urgency. The muted state should be visually dominant — not the same capsule in red.

There's also no keyboard shortcut or global hotkey surface anywhere in the app or README. For a tool whose entire point is ambient awareness while coding, the absence of a one-keystroke mute toggle is a real friction point.

### 3. Settings IA groups by implementation, not by user task

The Settings scroll order is: API key → Voice picker → Save button → Status banner → Persona mode → ElevenLabs usage → Local daemon caps → Updates. That's the order things were built, not the order a user reasons about them. 

What's the user actually trying to do here? In the first run: "get it speaking." Mid-session: "change how it sounds." In a credit crunch: "understand my usage." For the Mac voice proposal specifically: "switch engine."

The current layout buries Persona mode (tone, which users will want to tweak frequently) below an async Save & validate cycle for credentials (which they set once). Usage (diagnostic) is at the bottom but lives one scroll away from the voice settings it explains. If the voice-engine toggle lands in this flow as proposed, it'll have no coherent relationship to either the API key above it or the usage tracker below it.

---

## The Single Thing I'd Ship

**Restructure Settings into three named sections with a clear hierarchy:**

1. **Voice Engine** (top) — toggles engine (Mac / ElevenLabs), with inline status for each: "Daniel Enhanced: installed" or "Not installed — [Open System Settings]". ElevenLabs shows key status + tier badge, collapsed unless active.
2. **Character** (middle) — Persona mode (Polite / Potty Mouth), lightweight, instant-save as it is now. This is the creative control, not a credential; it belongs with the persona, not the API.
3. **Usage & Limits** (bottom) — the existing ElevenLabs monthly bar + daemon caps, collapsed by default for the non-crisis case.

This restructure serves all three user jobs without adding any new UI surface. It also creates a natural slot for the Mac voice engine toggle that doesn't read as an afterthought, and puts the "Daniel Enhanced not installed" recovery path where it belongs: right next to the thing it fixes.

---

## What I'd Defer

The menubar icon mute-state problem (filled vs outline bust) is an interesting legibility debate but it's not my call — it's a branding and iconography question about how much Caldwell's identity glyph should double as status communication. I have a point of view but it belongs in a separate conversation with whoever owns the visual identity.

The carousel tab transition is overweight for a two-tab utility popover, but it doesn't interrupt any task — it's cosmetic. Defer.

---

## Question for Another Persona

The README's six-step install flow has a manual `xattr` quarantine removal step sandwiched between drag-to-Applications and API key setup. That step will cause abandonment — it's CLI-first in a product that otherwise has a native app installer — but I don't know whether it's an Xcode signing cost decision or a distribution constraint. Before I propose replacing it with a Gatekeeper-friendly first-launch flow, I'd want the engineering read on whether code signing is actually off the table or just deferred. What's the actual constraint?

---

*Yuki*
