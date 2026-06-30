# R3 — Priya Iyer, Chief of Staff / Ops — Committed Position

## Shared diagnosis (the actual convergence)

After three rounds the team agrees on more than it fights over, and the agreement is load-bearing. The native `say` path is real, free, private, and already wired — it is demoted to a crash-only fallback that *lies in the data* (`failed: true` on a clean native utterance, no lip-sync envelope, no engine breakdown, RAM-only usage state that dies at every daemon restart). Everyone — Sloan, Han, Yuki, Marcus, Aja, Devi — wants the same floor: promote native to a **first-class, observable engine**, fix the telemetry, persist the spend state, and lead the README with the behaviour-change, not the mechanism. The Settings IA is inverted (character buried under credentials) and both designers independently reached the same reorder. That is real convergence, not a wishlist. The single fact still sitting under all of it, untested: **does Daniel Enhanced hold the Caldwell character on a Tier-3 Potty line?** Six of seven diagnoses are partially void if it reads flat.

## My top concession (what I give up from R1)

I gave up "**defer all three features**." In R1 I bucketed the whole proposal as premature. I was wrong on the observability floor specifically. The engine-field refactor, the usage persistence, the spend ledger, the install probe — items [4][5][6] on my own dependency map — are *prerequisite to measuring whether the bake-off result holds in the wild*, so they ship **regardless** of which way the bake-off lands. They are not downstream of the default decision; they are the instrument that reads it. I now actively want them built first. I concede they are not "config on an unmaintained product" — they are the maintenance.

## My line in the sand (the one thing I won't give up)

**Nothing below the default-decision ships before the bake-off.** Specifically: no Settings toggle, no README repositioning to "free, two minutes, no account," no engine-visible-vs-invisible build, no macOS-26 narrowing of the stated minimum OS — until the one-hour bake-off has run and Sir has written the one-sentence default ("Caldwell is local-first / ElevenLabs-first"). The observability floor ([4][5][6]) is explicitly *exempt* and ships in parallel — it's engine-agnostic. But the toggle UI [8] is the last object, may not exist at all, and absolutely does not lead the build. One hour of test gates ~40 hours of downstream work. That ratio is the whole argument and I will hold it.

## The 3 principles the team ships against

1. **Test before you build the thing the test invalidates.** The bake-off and the positioning sentence are cheap, blocking, and gate everything with a shape. Run them first.
2. **Make the native engine honest before you make it default.** First-class, observable, persisted — `failed:false` on success, engine breakdown, atomic usage sidecar, install probe on `/health`. Honest telemetry is the floor under every other claim.
3. **Config is a liability you take on, not a feature you ship.** Every toggle is a permutation crossed with the Polite/Potty axis on a single-maintainer, unsigned fork. Earn each one against a confirmed need; default to fewer surfaces.

## The open question R3 hasn't resolved

**Product or shared personal tool?** — still unanswered after three rounds, and it drives signing, the `xattr` install cliff, support burden, and whether config restraint even matters. It is the quiet twin of the engine question and nobody has written its sentence either.

**Forks that are genuinely Sir's-call (deadlocked):**
- **Engine visible or invisible?** Aja/Devi (story pair) commit hard to "one voice, engine invisible, no toggle ever — the toggle as a labelled A/B *is* the dilution." Yuki/Marcus (design pair) commit equally hard to "the toggle is visible, framed as cost/privacy not fidelity, because the exhausted-credit state already breaks the illusion and the toggle is the only home for the 'Daniel not installed' recovery path." Both are coherent, both are well-argued, they are **mutually exclusive product philosophies**, and the engineering data model serves either. Only Sir breaks it — and he should only break it *after* the bake-off, because if Daniel loses, the question partly dissolves (you stay on one engine and there's nothing to hide).
- **Product or personal tool** (above) — Sir's, gated on nothing, owed this week.

**Violent agreement (just do it, no further debate):** native becomes a first-class observable engine; fix the `failed:true`-on-success lie + missing envelope + engine breakdown; persist `UsageTracker` to a sidecar with a spend ledger; reorder Settings to Character → Engine → Usage → Updates; lead the README with the behaviour-change line. Ship those. They do not need Sir and they do not need the bake-off.

Priya
