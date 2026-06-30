# R1 — Priya Iyer, Chief of Staff / Ops

## Verdict

**It's a finished personal tool wearing a product costume, and nobody in this room has decided which one we're shipping. That's the real risk — not the code, the *decision*.** The 3-feature proposal is fine. It's also premature, because we're optimising the engine before we've named the buyer.

## Top 3 findings

**1. The "product vs personal tool" question is unanswered — and everything downstream is blocked on it.** The README reads like a real product (download badge, Sparkle auto-updates, DMG releases, install flow). The reality is a one-person fork of `tomc98/speak` with a Caldwell skin. Those are two different commitments. If it's a *product*, you owe strangers: signing (the `xattr -dr com.apple.quarantine` step is a hard install cliff — most non-developers quit there), support, and a setup that doesn't require symlinking into `~/.claude/skills` and hand-editing `settings.json`. If it's a *personal tool you're sharing*, none of that matters and the 3 features are just Tuesday. **Owner: Justin (notional — he's the whole team). By Friday: write one sentence — "Caldwell is X for Y" — and tape it to the monitor. Every scope call flows from that sentence.** Without it, every review round re-litigates the same ambiguity.

**2. The unspoken assumption: the free-Mac-voice "game-changer" gets *celebrated* before it gets *de-risked*.** Daniel Enhanced rivalling ElevenLabs is genuinely the most important thing on the table — a free, no-API-key path collapses the single biggest adoption blocker (sign up for ElevenLabs, generate a key, paste it, fund it). But notice what nobody's saying out loud: **it's macOS-26-only**, and the README still advertises macOS 14+. So the repositioning that makes the product *accessible* simultaneously makes it *narrower* — you'd be trading "anyone on Sonoma with an ElevenLabs key" for "anyone on the newest OS, no key needed." That might be the right trade. But it's a trade, not a free win, and right now it's being filed under "win." Also unvalidated: does Daniel Enhanced *hold the Caldwell character*? ElevenLabs was chosen because it carries RP-butler register and audio tags (`[dry]`, `[deadpan]`). If the local voice reads flat, the whole bit dies and "free" is worthless. **Nobody has A/B'd the two on the same Tier 3 line. That's the test, and it's a one-hour test.**

**3. Bus factor is total, and the proposal adds surface to a thing one person already can't fully maintain.** Single maintainer, fork of an upstream that will drift, unsigned binary, Swift menu-bar app + bash hooks + a daemon + a skill contract — four moving layers, one human. Three *more* toggles (voice-engine, message-style, auto-enhanced-voice) is three more settings-state permutations to test, document, and support, each with a Polite/Potty axis on top. **Velocity discipline says: you don't add config to an unmaintained product. You add config to a maintained one.** Right now Caldwell has zero install telemetry, zero issue triage process, zero "is anyone but Justin using this" signal. Building features into that void is motion, not progress.

## The single thing to ship/decide first

**Run the one-hour voice bake-off: Daniel Enhanced vs ElevenLabs, same three Caldwell lines (one Tier 0, one Tier 2, one Tier 3 with an audio tag), Potty mode.** That single test answers the only question that actually reprices the product. If Daniel holds the character → the free-path repositioning is real and *that* becomes the headline, demoting all three proposed toggles to "nice." If it doesn't → ElevenLabs stays load-bearing and the macOS-26 narrowing isn't worth it. Either way you've turned the "game-changer" from a vibe into a decision. **Owner: Justin. By Friday.**

## What I'd defer

All three proposed features. The voice-engine toggle is downstream of the bake-off (don't build a toggle between two engines until you've proven both carry the character). The message-style toggle is polish on a product with no confirmed second user. Auto-enhanced-voice is an optimisation of a path you haven't committed to. None of them move the one needle that matters this week. Defer them behind the positioning sentence and the bake-off — both cheap, both blocking.

## One question for another persona

**For the engineer (Sloan):** if Daniel Enhanced wins the bake-off and we pivot to local-voice-first, how much of the ElevenLabs daemon, phrase-cache, and spend-cap machinery becomes *dead weight* — and is the macOS-26 API surface stable enough to bet the product on, or are we one OS point-release from a broken voice path?

Priya
