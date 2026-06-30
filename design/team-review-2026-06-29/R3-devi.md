# R3 — Devi Sharma (Growth / Product Marketing)
_Round 3 — committed position — Caldwell voice companion for Claude Code_

---

## Shared diagnosis

Three rounds in, the team has converged on one real thing and is still circling one fake debate. The real convergence: the free local voice is not a cost-saving tweak — it is a **funnel redesign**. Sloan and Han agree the plumbing to support it is already there. Marcus and Yuki agree the Settings IA must lead with character, not credentials. Aja and I agree the first syllable a new user hears is the cached canon line, and that it's both the brand hero and the activation aha. The fake debate is whether the engine should be "visible" or "invisible" — it kept R2 occupied for a full round and is mostly downstream of a one-hour bake-off nobody has run yet. The team is decorating a house whose foundation is an untested claim. If Daniel Enhanced holds the character, the R2 story-pair verdict ("one voice, engine invisible, free by default") is correct and the toggle question resolves itself: there's no reason to expose what doesn't need choosing. If it doesn't hold, we're back to ElevenLabs as the load-bearing voice and the funnel problem shifts from "engine" to "onboarding friction." Either way, the toggle-vs-no-toggle fight was premature.

---

## Top concession

In R1 I argued the engine toggle should be **front-and-center in the README** — a visible, labelled choice between ElevenLabs and Mac voice. I'm giving that up. Aja persuaded me in R2 and the logic holds: the moment the operator sees "ElevenLabs / Daniel Enhanced" as a labelled A/B, the voice becomes a costume and the identity collapses. The correct framing isn't "choose your engine" — it's "Caldwell works free, two minutes, no account." The outcome (free, fast activation) is identical; the *surfacing* of the engine name is what causes the brand dilution. I concede the toggle-in-README framing entirely. **The cost:** we lose one explicit README affordance for users who want to understand the mechanism. That's acceptable — developers who care will find the technical detail in a secondary section; we don't owe them the engine name in the lede.

---

## Line in the sand

The free Mac voice path must be the **default onboarding experience** — not a buried fallback, not a power-user setting, not a post-aha discovery. ElevenLabs is a quality upgrade surfaced *after* the first Caldwell line lands. I will not trade this. Every other concession in this review round is negotiable. This one changes the activation funnel from a 7-step, 2-account, API-key-gated ordeal to a 2-minute, zero-dependency aha. That is the single biggest conversion lever in the whole product. If Daniel Enhanced fails the bake-off this point is moot — but if it passes, burying the free path to protect brand purity is the wrong trade. A product no one activates has no brand to protect. The positioning sentence ships as: *"Caldwell is a butler who lives in your terminal and tells you — out loud — the moment your code is done. Free. Two minutes. No account."* That's the lede or we lose the funnel.

---

## Vote: 3 principles the team ships against

1. **Bake-off first, toggle never.** Run the one-hour Daniel Enhanced vs ElevenLabs comparison (same three lines: T0 canon, T2 milestone, T3 with audio-tag intent rewritten into words — Potty mode) before building any UI for engine selection. If Daniel wins, ship the free path as default with engine invisible; if it loses, the toggle question becomes moot because we stay ElevenLabs-only. The bake-off is not a nice-to-have; it gates the shape of every surface below it.

2. **The signature is the aha.** "Pushed, Sir." ships pre-seeded in the canon, goes on the download page as the demo, and is explicitly named as the brand's signature move in SKILL.md — not filed as a cheap fallback. The cache fills with your sessions and sounds like *your* butler over time; that retention story goes in the README. Brand hero and activation aha are the same asset.

3. **Free path is the default, not the footnote.** The README lede leads with the behaviour change ("you hear a voice when Claude Code finishes — you stop watching the screen"), establishes Caldwell in one sentence, and offers the zero-config path as the primary onboarding. ElevenLabs lives in an "upgrade the voice" section below. No account required to hear Caldwell for the first time.

---

## One open question R3 hasn't resolved

**Does "product vs personal tool" actually need deciding before the free-voice default ships?** Priya flagged this as blocking in R1, and the team has carried it forward unresolved. But I'd argue it's not the gating question people think it is. The free-voice default and the README pivot are exactly the same work whether this is a personal tool you're sharing or a product for strangers — same lede, same activation path, same canon seeding. The decision that *actually* depends on "product vs personal tool" is code-signing and the `xattr` cliff (Yuki's R1 install question), not the voice default. Those are genuinely separate tracks. You can flip the free-voice default and rewrite the README on Friday afternoon without resolving the product-or-not question at all. The positioning sentence might even answer the question for you: if you write "Caldwell is a butler for solo devs who live in Claude Code Desktop" and it feels true, ship it and call it a product. If it feels like a lie, it's still a personal tool, and the voice default still ships exactly the same way. The debate has been expensive and mostly circular; I'd suggest separating it from the voice-default work entirely and letting the bake-off result force the positioning sentence naturally.

---

_Devi_
