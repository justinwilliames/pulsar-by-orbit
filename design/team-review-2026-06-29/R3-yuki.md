# R3 — Yuki Tanaka, Senior UX Designer
**Date:** 2026-06-29 · Round 3 (convergence)

---

## Shared Diagnosis

The team has reached genuine convergence on the data layer and the IA — not wishlist convergence, real convergence: every reviewer independently identified the same wrong hierarchy (credentials above character), the same lying telemetry (native success recorded as failure), and the same funnel cliff (ElevenLabs gate before any aha). The creative-vs-UX deadlock on toggle visibility is the only remaining fork, and the engineering pair correctly identified that it cannot be resolved by design alone — it depends on whether the bake-off proves Daniel Enhanced holds the Caldwell character under load. That's not a failure of this review; that's the review working. The dependency order Priya mapped is the actual critical path, and the team should stop arguing about Settings surfaces until [1] and [3] are settled.

---

## My Top Concession

In R1 I pushed for the engine choice as a top-level, symmetric segmented control — ElevenLabs | Mac — on the grounds that peer-level visibility gives the user the clearest mental model for what's happening. I'm giving that up. Marcus is right on visual semantics: two segmented controls side-by-side (Character | Engine) signal equal-weight decisions, and they aren't. Engine is infrastructure. Character is identity. The resolved R2 design pair layout — a macOS Toggle with a one-line caption inside a VOICE ENGINE section, the character segmented control above it in its own CHARACTER section — carries exactly the same recovery path and install-status affordance I required, without the false-equivalence signal. The cost is that the Toggle grammar is slightly softer as a primary affordance than a segmented control; the gain is that it no longer tells the user "who Caldwell sounds like is a peer choice to who Caldwell is." Worth it.

---

## My Line in the Sand

The exhausted-credit recovery path stays visible and in-context — I will not trade this away regardless of how the invisible-engine debate resolves.

Here's why this is non-negotiable: if the story pair wins (engine invisible, one Caldwell voice, no toggle), the exhausted-credit state is still a real user moment where Caldwell goes silent and the operator has no idea why. Even in the invisible-engine world, the user needs an in-context signal that says "Caldwell is quiet because X, and here's what to do." Whether that's "credits exhausted — Caldwell switches to local voice automatically" (if Daniel Enhanced passes the bake-off) or "credits exhausted — add funds or Caldwell goes quiet until reset" (if it doesn't), the affordance must be inline, at the point of relevance, not buried in a README.

If the team ships invisible routing AND removes the exhausted-state recovery surface on grounds that "Caldwell just works, engine hidden," we have built a product where silence is the only feedback at a critical failure point, with no path back. That's not brand integrity — that's a dark pattern wearing a butler costume. I will not sign off on that, even under Aja's "one identity" framing.

The recovery path doesn't require labelling the engine. It requires explaining the state and offering an action. Those are different things.

---

## My Vote: Three Principles the Team Ships Against

1. **Character is above the fold; infrastructure is not.** The persona control (Polite/Potty Mouth) earns the top position in every Settings surface. Credentials, engine toggles, usage meters — all below it, collapsed by default until needed. First-run or crisis-mode, the user's first touch is Caldwell's identity, not a form.

2. **Every silent state has a recovery path.** Muted, credit-exhausted, Daniel Enhanced not installed, budget-downgraded — each produces a visible, in-context signal with a one-tap action wherever technically possible. Silent degradation is not a feature; it is a trust failure. This principle applies whether the engine is visible or not.

3. **The bake-off gates the toggle, not the other way around.** No Settings surface ships for the engine choice until Daniel Enhanced has been tested on a Tier 3 Potty-mode line with an audio tag. If it passes, the toggle (or invisible routing, depending on [3]) ships with the caption "Caldwell sounds like Caldwell either way." If it doesn't, the toggle grammar changes to honest capability disclosure. We do not build UI for an untested engine.

---

## One Open Question R3 Hasn't Resolved

The design pair asked engineering for the correct install probe strategy — parse `say -v '?'` vs. zero-length synthesis probe — and got no answer in time for R3. That probe is the source of truth for the inline status indicator in Section 2 (the green checkmark vs. the orange "not installed" recovery link). Without it, the Settings design is complete in layout but has an unresolved data dependency. The engineering pair should close that before any Settings implementation starts — it is not a detail to resolve in a PR comment.

---

*Yuki*
