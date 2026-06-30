# R2 — Story Pair Cross-Reference

**Aja Williams (Creative Director) × Devi Sharma (Growth / Product Marketing)**
_Round 2 — brand soul meets the funnel. Caldwell voice companion for Claude Code._

---

## Where we agree

**Devi:** We agree on the spine. Aja's R1 found the signature — **"Pushed, Sir."** filed under petty cash — and that's also the activation aha. The first syllable a new user hears _is_ the cached canon line. Brand hero and funnel hero are the same asset. That's rare and we should bank it.

**Aja:** Agreed, and it resolves my biggest fear cheaply: the seeded canon set ships pre-loaded, it's the download-page demo, and it's the thing that greets you in the first two minutes. The signature carries both jobs. We also agree the README lede is a mechanism description ("Alfred meets ElevenLabs") and must become a behaviour-change line. Neither of us is precious about that.

**Devi:** And we agree the engine is plumbing, not a headline. Where we fight is what the operator is allowed to _see_.

---

## Where we fight

**Aja:** Here's the line I won't cross. The moment you put "ElevenLabs / Mac voice" in front of the user as a labelled choice, you've told them the voice is a costume. Caldwell has a face, a name, a "Sir." A someone has _one_ voice. Demote ElevenLabs to "upgrade" and you've made the engine a visible tier — now the portrait above it is lying about which mouth is moving. Your funnel logic is right; your _surfacing_ of it is the dilution.

**Devi:** And if you hide the free path entirely, users burn a week of ElevenLabs credits — or worse, bounce at the API-key wall in step 2 of 7 — before discovering the thing was free all along. Yuki said it in R1: people hit the exhausted banner with nowhere to go. The free voice is the single biggest collapse in the activation funnel I have ever seen on this product. I will not bury it to protect a portrait.

**Aja:** I'm not asking you to bury the _outcome_. I'm asking you to bury the _engine name_. There's a difference between "Caldwell works free, in two minutes, no account" and "choose your TTS provider."

**Devi:** …that's actually a deal. Say more.

---

## The resolution — win, not dilution (with one condition)

**Aja:** The free Mac voice is a brand **WIN** — _if and only if_ it ships as **Caldwell's voice**, never as "the Daniel Enhanced engine." Same name, same face, same canon. The operator hears Caldwell. Full stop. The engine is invisible plumbing — Han and Sloan can route per-line, fall back on a credit crunch, whatever the cost math wants, behind the curtain. One identity, engine hidden. That's the whole brand non-negotiable from R1, and the free path _satisfies_ it rather than threatening it.

**Devi:** And it's a growth win on the same condition. The pitch is no longer "configure a TTS API." It's "your code assistant speaks to you like a butler — free, two minutes, no account." That's a fundamentally more spreadable claim. The condition I add: the free path is the **default onboarding** and ElevenLabs is a quiet quality upgrade discovered _after_ the aha, not a gate before it. So we both win by deleting the same thing — **the visible engine toggle.** Marcus's R1 instinct (a system Toggle with a one-line caption, not a second segmented control, never peer to the Polite/Potty character control) is the UI expression of exactly this. Character is a choice the user sees; engine is not.

**Verdict: WIN.** Free Caldwell for everyone, one voice, engine invisible. Dilution only happens if someone ships the toggle as a labelled A/B.

---

## The pitch and who it's for

**Devi (pitch):** _"Caldwell is a butler who lives in your terminal and tells you — out loud — the moment your code is done, so you stop babysitting the screen."_ Free, two minutes, no account.

**Devi (who):** The solo dev / power-user who lives in Claude Code Desktop all day and wants ambient aural "it's finished" feedback with a character that breaks the terminal monotony. R1 sized it at ~500–5k who'd get it instantly. The free-voice funnel widens the _top_ — anyone curious can hear Caldwell in two minutes with nothing to sign up for. ElevenLabs becomes the retention/upgrade surface for the ones who fall for him.

**Aja:** And the retention story Devi named in R1 — the cache fills with _your_ sessions, so over time he sounds like _your_ butler, not a generic one — only holds if the voice never visibly changes underneath. Invisible engine isn't just brand purity; it's what makes "your Caldwell" coherent as he learns your rhythm. The two arguments are the same argument.

---

## What the bake-off must prove (Priya's unresolved question)

**Aja:** Everything above is built on sand until someone proves **Daniel Enhanced holds the character.** The bake-off — same three lines (one Tier 0 canon, one Tier 2 milestone, one Tier 3 with an audio tag), Potty mode — must clear a hard bar, not a "close enough" one:

1. **RP register survives.** It reads as a composed English butler, not a flat system voice.
2. **The 95/5 dial lands.** The expletive in Potty mode has _crispness_ — the swing from butler-formal to the crisp landing is audible. If the swear reads flat, the whole bit dies (Priya's point).
3. **Audio-tag intent is approximated.** ElevenLabs honours `[dry]`/`[deadpan]`; Daniel won't read tags, so the bake-off must prove the line still lands _without_ them, or that we rewrite canon to carry tone in words.

**Devi:** If it clears that bar → free path is the default, repositioning is real, ship it. If it _doesn't_:

## Fallback narrative if Enhanced isn't good enough

**Aja:** Then we do **not** dilute Caldwell to chase free. ElevenLabs stays the one true voice, and the pitch narrows back to "the premium butler" — fewer users, intact soul. We never ship a worse voice under his name to win a funnel; a flat Caldwell is a dead Caldwell.

**Devi:** And the funnel fix shifts from "free engine" to "radically shorten the paid setup" — kill the API-key friction with a guided first-run, a generous trial, anything that moves the aha before the wall. We'd lose the zero-cost headline but keep an honest product. The free voice was the _best_ unlock, not the _only_ one. Importantly — and this is on Priya's flag — the macOS-26-only constraint means even a _win_ narrows the OS base; so "free" is a trade, not a freebie, and the bake-off has to be worth that trade, not just pass.

---

## One question for the other pairs / orchestrator

**To the orchestrator (and Sloan/Han):** the entire WIN verdict rests on per-line engine routing being **invisible and seamless** — no audible voice-change mid-session, no portrait desync when the engine flips on a credit crunch. R1 (Sloan) flagged the native path never computes a lip-sync envelope and mislabels success as failure; R1 (Han) flagged launch-amnesia in the spend gate. **Can engineering guarantee a single continuous Caldwell — same perceived voice, moving portrait — when the engine silently switches per-line? If not, we cannot ship "one invisible voice," and the brand non-negotiable forces us to pick ONE engine and stay on it.** That answer gates the positioning.
