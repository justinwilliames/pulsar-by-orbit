# R3 — Marcus Holm, Product Designer (UI + craft)
_Round 3 — convergence_

---

## Shared diagnosis

The team has arrived at something real: the data-layer fixes (Sloan/Han's `engine` field, the ledger, the lie about `failed: true` on native success) are now violent agreement — no one is fighting them. The Settings IA inversion is also settled; Yuki and I already resolved the specific section structure and the Toggle-vs-segmented grammar in R2. What remains genuinely forked is whether the engine choice is *visible* at all, and that fork has sharpened cleanly: Aja and Devi's story-pair output gives us the only clean resolution — engine invisible, but only if the bake-off proves Daniel holds the character. If it does, the toggle I designed in R2 never ships. If it doesn't, it ships as a fallback-disclosure affordance, not a peer choice. The whole team has essentially agreed that the bake-off is the gate and Priya's dependency graph is correct. The residual mess is not a design dispute; it's an undone one-hour test.

---

## My top concession

In R1 I proposed a `Toggle`-with-caption as the engine control — "USE ELEVENLABS: off means Daniel Enhanced, free, local." I was right that it shouldn't be a second segmented control. But Aja and Devi's R2 joint output makes the stronger case: if Daniel passes the bake-off, *any* engine control — even my carefully-framed one — still tells Sir the voice is a costume. My framing ("it's spend and privacy, not fidelity") was a design rationalisation trying to thread a needle that shouldn't exist. The cost is real: hiding the toggle means the Settings IA Yuki and I resolved in R2 now has a hole where Section 2 lived. That hole needs filling with something, even if it's only the Mac-voice install-status indicator and a credit-threshold note, not an engine choice. I give up the toggle as a first-class control. The install-status and the exhausted-credit recovery path still need a visible home; they just stop being framed as a *choice*.

---

## My line in the sand

**The Polite/Potty-Mouth segmented control belongs above the fold — full stop, no trade.**

This is the one craft position I will not give up regardless of what the bake-off decides, regardless of whether the engine is visible or invisible, regardless of whether we are a product or a personal tool. The Settings view currently buries the brand-expressible element below credentials, below a Save cycle, below a status banner. That is not a hierarchy; it is an accident of build order. Character above the fold is the moment a new user grins. It earns the pixel. Everything else in that panel — credentials, engine plumbing, usage bars, update checks — is infrastructure that can sit in collapsed DisclosureGroups below it. If we come out of the bake-off having decided engine is invisible and Section 2 dissolves into a credit-status note, then CHARACTER gets more room, not less. That's the right outcome. But if the IA restructure gets deferred to "after we solve the toggle question" — which Priya's note flags as a risk — I am pulling it back in. The Mode control above the fold is a one-afternoon diff that unlocks the brand moment on every launch. It has no dependencies on the bake-off. It should already be done.

---

## My vote for 3 principles the team ships against

**1. Character is primary; engine is plumbing.** Every surface decision — IA order, grammar of controls, framing of captions — follows from this. The persona toggle is a choice Sir sees; the engine is not (if the bake-off passes) or is a disclosure-level fallback affordance (if it doesn't). Never peer-level, never labelled as a voice-quality option.

**2. Earn the pixel or cut the chrome.** No new UI surface ships without a job it owns. The design pair's Settings IA already produces this — collapsed DisclosureGroups for credentials, usage, daemon caps. Apply the same test to anything proposed downstream: statusline glyph, message-style toggle, install-status indicator. If it doesn't answer a real user question at the moment they have it, it's decoration, and decoration is a maintenance liability on a single-maintainer codebase.

**3. Bake-off gates everything; don't build around unknowns.** This one is borrowed from Priya, but it's a design principle too: every frame I spec, every hierarchy I argue for, should be built on measured facts about the product's own voice. Design around untested assumptions produces the wrong object confidently. Run the test. Then finish the surface.

---

## One open question R3 hasn't resolved

**If Daniel passes the bake-off and the engine is hidden, what surfaces the credit exhaustion gracefully without breaking the illusion?**

The story pair's WIN verdict assumes seamless invisible switching. But the R2 design pair's own layout (the exhausted-credit conditional banner in Section 2) relied on the Toggle being present to give that banner a home. If the Toggle disappears, the exhaustion state needs a new surface — and "Caldwell went silent with no explanation" is not it. The engineering pair noted that when the canon cache is cold on a fresh launch and the gate fails open, there's a silent spend hole; if the gate silently switches to local on exhaustion, and the portrait freezes because the native path still doesn't compute an envelope (Sloan's finding, unresolved), Sir sees a butler who stopped moving his mouth and never said why. That's worse for the brand illusion than a toggle. So the open question is: **what is the minimum graceful surface for credit-exhaustion state in a toggle-invisible world?** It's a UX question Yuki and I don't yet have an answer for, because we built Section 2 around the Toggle being the container.

---

Marcus
