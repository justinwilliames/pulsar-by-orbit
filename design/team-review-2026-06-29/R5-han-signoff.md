# R5 — Han Müller (Staff Backend / Data Engineer) — Sign-off

**I agree.**

My R3 line was one sentence: no trust in the spend gate, and not one word of "private / local / no-credits," until spend is persisted to an atomic sidecar and every decision is logged to an append-only ledger. The action plan honours it without dilution.

- **Ship-now #2** is exactly the floor I asked for — atomic `usage-state.json` sidecar plus an append-only per-decision ledger carrying engine, chars, decision (including the `budget-fellthrough` case I care about most), and health. It explicitly seeds the gate at launch so it stops failing open on the cold-cache ping burst at `CaldwellHTTPServer.swift:1014`. That closes the amnesia hole and the untraced fall-through in one pour.
- **Queue #3** binds the README's privacy/sovereignty language to that ledger as a hard gate — "a claim you can't audit is marketing, not a guarantee." The README "sovereignty gate" is my line, written down.
- The **carried open-question** on sovereignty timing flags the gate so it can't be quietly skipped if the rewrite feels ready before the ledger lands. Good. That was my one fear and it's logged.

**One caveat I'm not blocking on:** my R3 open question still stands — if the bake-off flips the default to local-first, the gate's job shrinks to "consult usage only on an explicit ElevenLabs line," and the `health` field goes near-dead for most sessions. We should spec the post-flip *shape* of the gate before building it out, not after. That's a sequencing note for whoever owns #2 once Sir's call #2 lands — not a reason to hold the floor.

**What I learned:** Sloan was right that the `engine` field and persistence are orthogonal — I'd conflated "the floor" with "one atomic ship." Pouring it in two pours loses days, not the guarantee, because the ledger renders the gap visible the moment it lands.

— Han
