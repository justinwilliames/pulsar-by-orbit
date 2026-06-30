# Caldwell — Final Shipping Decision — 2026-06-29

Seven personas, five rounds, **zero blocks** (5 agree-with-caveat, 2 clean
agree). Full detail in `R4-orchestrator-action-plan.md`; the per-round files
`R1-*`, `R2-*`, `R3-*`, `R5-*` hold the working.

## The three principles

1. **Observable before selectable / record before manage.** No engine becomes a
   user-facing choice or a silent auto-route until it's first-class in the data:
   honest success flag, own history type, computed lip-sync envelope, `/health`
   install probe, persisted per-utterance spend ledger.
2. **Every silent state has a recovery path.** Muted, exhausted, Daniel-not-
   installed, budget-downgraded — each gets a visible in-context signal with a
   one-tap action. Silent failure at a cost/capability boundary is a dark pattern.
3. **One identity; character is the choice, engine is plumbing.** One name, one
   face, one canon. "Daniel"/"ElevenLabs" never reach the operator as a quality
   tier. The operator controls persona and (at most) cost/privacy — never who
   Caldwell is.

## The one refinement all five caveats produced

Sloan, Yuki, Aja (and implicitly Marcus, Han) independently converged on a single
amendment to the plan:

> **Disclose the fallback switch.** When ElevenLabs exhausts mid-session and the
> local voice takes over, the voice audibly changes — seamless per-line switching
> is NOT deliverable. The brand-safe resolution is an honest, in-character
> acknowledgement ("switching to the local voice, Sir") rather than a silent swap.
> This closes the R3 "audible switch" open question and is the prerequisite for
> the Settings top section and recovery-banner copy.

Notably, this is exactly the "falls back to the Mac voice when credits run out"
note Sir requested at the outset — operator instinct and team verdict agree.

## Action plan (summary; full version in R4)

**Ship now (48h):** (1) `engine` field on `AudioEntry` + honest native playback
[Sloan, ½d]; (2) persisted spend ledger + close the cold-cache fail-open spend
hole [Han, 1d]; (3) `/health` voice-install probe [Sloan, 2h]; (4) Polite/Potty
control above the fold [Marcus, 1 afternoon]; (5) **the one-hour bake-off**
[Priya/Sir]; (6) fix README macOS-26 claim [Priya, 10m].

**Queue (this week, after bake-off + Sir's calls):** Settings IA restructure
(Character → Voice → Usage/Limits → Updates); recovery banners for every silent
state; README lede rewrite (free-voice-first) — *gated on the audit ledger before
any "private/local" claim*; robust config.json parsing; message-style toggle;
canonise "Pushed, Sir."

**Defer:** product packaging / distribution (until "product vs personal" decided);
voice tuning beyond rate; any second fallback voice.

**Sir's calls:** (1) engine invisible-auto vs visible-cost/privacy control —
decide *after* the bake-off; if invisible, it's pick-one-engine-per-session +
disclosure, never per-line. (2) Default voice local-first vs ElevenLabs-first —
gated on the bake-off. (3) Product or personal tool — write the one sentence;
"personal, shareable if asked" is a legitimate, freeing answer.

## The seven sign-offs

- **Sloan** — AGREE w/ caveat: invisible-auto must be pick-one-engine-per-session,
  not a per-line router; disclosure on fallback is the brand-safe path. Floor
  unblocked regardless. *Learned: the free engine was always there — it just
  needed to stop lying in the data.*
- **Yuki** — AGREE w/ caveat: close the audible-switch question before the
  Settings top section locks; recovery-banner copy depends on it.
- **Marcus** — AGREE w/ caveat: the credit-exhaustion surface needs one more IA
  pass before the Voice section finalises (queued, non-blocking).
- **Aja** — AGREE w/ caveat: "sounds like Caldwell either way" is gated on the
  switch being imperceptible OR an honest acknowledgement; option B's label stays
  cost/privacy, never engine-name or quality.
- **Devi** — AGREE.
- **Han** — AGREE w/ caveat: if the default flips local-first, spec the spend
  gate's new shape before fully building the ledger (sequencing).
- **Priya** — AGREE.

## Send-off

The review did its job: it found that Caldwell's biggest move wasn't a new feature
but a re-reading of what it already is — a free, local, private butler with an
optional premium voice. The team will not let that ship as marketing before it's
true in the data (the ledger), nor let the brand fracture into a "pick your TTS
provider" utility. Build the floor now; run the hour-long bake-off; let the result
write the default; disclose the fallback out loud. Everything else waits on Sir's
three sentences. — *The orchestrator.*
