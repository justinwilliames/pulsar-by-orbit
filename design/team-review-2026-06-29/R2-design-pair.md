# R2 — Design Cross-Reference: Yuki Tanaka + Marcus Holm

**Date:** 2026-06-29
**Round:** 2 (pair reconciliation)
**Scope:** Settings IA, engine toggle decision, Mac-voice recovery path

---

## Where We Agree

**Yuki:** The current scroll order — API key at top, persona buried past a Save cycle — is the wrong hierarchy for every user job, first-run through crisis. We agree there unanimously.

**Marcus:** Same verdict, different framing: the Polite/Potty-Mouth segmented control is the brand-expressible element in the whole panel. It earns above-the-fold. Everything else is infrastructure. We converge on that ordering instinct: character first, credentials last.

**Both:** The status-banner pattern (tinted, rounded, `caption`) is the right explanatory note grammar for this panel. Don't introduce a third variant — callout box, modal, tooltip — when the pattern's already there and working. The Mac-voice status and the fallback note both live in this idiom, not new chrome.

**Both:** The `DisclosureGroup` for LOCAL DAEMON CAPS is correct — diagnostic data stays collapsed by default. That pattern should extend to the ElevenLabs credential block once Mac-voice is a peer engine, not an afterthought.

---

## Where We Fight

**The engine control's grammar.** Yuki wants a top-level segmented control — ElevenLabs | Mac — symmetric peers, highest visual prominence. Marcus wants a `Toggle` (standard macOS switch) with caption, because segmented grammar means "who is Caldwell," while a toggle means "system setting." Two segmented controls side-by-side — one for character, one for engine — would read as equal decisions. They aren't. Engine is plumbing. Marcus wins this on visual-semantics grounds.

**Section count.** Yuki proposes three named sections: Voice Engine → Character → Usage. Marcus proposes five: Mode → Voice → Credentials → Usage → Updates. The five-section version has the right instinct about label granularity — Credentials should be its own collapsed disclosure, not lumped into a generic "Voice Engine" section — but five headers on a 360px panel creates a different hierarchy problem: everything has a label, nothing is primary. Yuki's three-section grouping gives the right reading speed. Resolution: use Yuki's three-section grouping with Marcus's collapsed-disclosure move applied inside the engine section.

---

## Resolved Settings IA — One Concrete Ordered Layout

### Section 1: CHARACTER
> Segmented control, instant-save (no Save button needed — matches current persona behaviour).
- **CALDWELL'S MODE** — `Picker(.segmented)`: Polite | Potty Mouth
- Caption: existing hint text, `caption2`, tertiary

This section is above the fold on the 520px panel at 16px padding. It is the first thing a returning user sees. It is the brand moment.

---

### Section 2: VOICE ENGINE
> `Toggle` (macOS switch, not segmented), with inline status beneath.
- **USE ELEVENLABS** — `Toggle`, right-aligned switch
  - Caption line 1 (always visible): "When off, Caldwell uses Daniel Enhanced — free, local, no credits."
  - Caption line 2 (conditional): appears only when the toggle is ON and quota is critical/exhausted — use the existing status-banner tinted pattern: "Monthly allowance exhausted. Switching to Mac voice until reset."
- **ELEVENLABS VOICE** — `DisclosureGroup`, defaults **closed** when toggle is OFF, **open** when toggle is ON
  - Inside: existing voice picker (preset `Picker(.menu)` + "Custom ID…" toggle + `SecureField` for API key + "Save & validate" button + status banner)
  - The entire credentials + voice-selection block lives inside this disclosure. When ElevenLabs is toggled off, Sir sees one clean toggle and a caption. When it's on, they expand to configure it.

**Mac voice install status** — inline, beneath the toggle, below caption:
- If Daniel Enhanced is confirmed installed (from `/health` probe): `Image(systemName: "checkmark.circle.fill") + "Daniel Enhanced — installed"` in green, `caption2`
- If not confirmed: `Image(systemName: "arrow.up.right.circle") + "Daniel Enhanced not installed — Open System Settings"` as a `Link` / `Button` that calls `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.speech")!)`. No tooltip burial. The recovery path is inline at the point of relevance — right next to the thing it fixes, exactly as Yuki prescribed.

---

### Section 3: USAGE & LIMITS
> `DisclosureGroup`, defaults **closed** unless status is warning/critical/exhausted (in which case it auto-expands — tie the `isExpanded` binding to a computed property on the usage model).
- ElevenLabs monthly bar — existing `MonthlyUsageBar` component, unchanged
- Run-rate badge, cycle range, reset countdown — unchanged
- LOCAL DAEMON CAPS nested `DisclosureGroup` inside — unchanged, always defaults closed

---

### Tail: UPDATES
- `CheckForUpdatesView` — unchanged, no header needed; sits below a `Divider()`

---

**Reading order produced:** Character (who is he?) → Engine (how does he speak?) → Usage (how much has he spent?) → Updates. That's the order a person actually reasons, across every user job: new user, returning tweaker, credit-crisis mode.

---

## Aja's Argument: Toggle Visible or Invisible?

Aja's case is serious and we didn't dismiss it. The argument: exposing an engine toggle tells the user the voice is a costume, which breaks the illusion of a named identity. "One voice, engine invisible" preserves both brand integrity and the free-tier win simultaneously.

**Our call: the toggle is visible. Here's why Aja's argument fails at this product's current stage.**

Aja's framing assumes a product where the brand illusion is already airtight — where the user *never* needs to know how Caldwell works, only that he does. That's the right long-term aspiration. But Caldwell today has a hard practical problem Aja's solution leaves unresolved: **the ElevenLabs exhausted state already breaks the illusion anyway.** The panel already shows a red "Exhausted" badge, an advice banner saying "New compositions will fail until reset," and silent failure when credits run dry. The user already knows Caldwell has a credit meter. The curtain isn't intact. Hiding the engine toggle doesn't restore the illusion — it just makes the fallback invisible without making it graceful.

The second problem: the app cannot download voices programmatically. It can only guide. That means any "silent swap" to Mac voice will silently fail if Daniel Enhanced isn't installed — and the user has no recovery path without an explicit surface for it. The toggle is how the install-status prompt becomes discoverable. Remove the toggle and you remove the only natural home for "Daniel Enhanced: not installed — here's how."

**The resolution that honours Aja's intent without hiding the seams:** the toggle is visible, but it is *not framed as a voice-quality choice.* The framing is cost and privacy, not fidelity. "USE ELEVENLABS — off means free, local, no credits." That positions it as spend control, not "pick your Caldwell." The caption carries "Caldwell sounds like Caldwell either way" — if and only if Priya's bake-off validates that claim first. If Daniel doesn't hold the character, the toggle stays but the caption changes: "Mac voice — free but different register." Honesty is cheaper than a brand lie.

---

## Mac-Voice Discoverability + Recovery Path Design

Given the app cannot download voices:

1. **Health probe at launch** (Sloan's recommendation, fully endorsed): `say -v "Daniel (Enhanced)" -o /dev/null ""` — result emitted on `/health`. This is the source of truth for the install-status indicator described above.

2. **Install-status inline in Section 2** — not a tooltip, not a README footnote. The green checkmark or the orange link is the first thing Sir sees beneath the toggle. One tap opens System Preferences > Accessibility > Spoken Content (the voice download lives there on macOS 15+). The Link destination is `x-apple.systempreferences:com.apple.preference.speech` — deep link, no hunting.

3. **Exhausted-credit handoff** — when `status == .exhausted` AND toggle is ON AND Daniel Enhanced is installed: auto-expand the Usage section AND show the tinted banner in the Voice Engine section: "Allowance exhausted — Caldwell is speaking locally until reset. No credits consumed." If Daniel is *not* installed in this state: the banner becomes an action: "Allowance exhausted. Install Daniel Enhanced to keep speaking — [Open System Settings]." The recovery path is contextual, not buried.

4. **Message-style toggle (cached vs bespoke-only)** — Yuki and Marcus agree this belongs at the bottom of Section 2, inside the ElevenLabs DisclosureGroup, with a `Toggle` and a single caption line. "Bespoke-only: every line composed fresh, higher credit spend." This is ElevenLabs-specific behaviour; it's invisible and irrelevant when the engine toggle is OFF.

---

## One Question for Another Pair

**For Sloan + Han (engineering pair):** The Section 2 design requires the `/health` endpoint to report Daniel Enhanced install status on every app launch. What's the correct probe strategy — parse `say -v '?'` output for the Enhanced variant name, or fire a zero-length `-o /dev/null` synthesis and check exit code? The failure behaviour differs: parsing the voice list is synchronous and cheap but version-string fragile; synthesis probe is reliable but adds ~200ms to daemon startup. Give us the one you'd trust in production and we'll wire the UI accordingly.

---

*Yuki + Marcus*
