# R3 — Han Müller (Staff Backend / Data Engineer) — Committed Position

## Shared diagnosis

Three rounds in, the room has actually converged — not on a wishlist, on a sequence. The native `say` path is real, free, private, and already trusted on the failure branch; promoting it is plumbing, not invention. Everyone now agrees on the data floor underneath it: `AudioEntry` needs a first-class `engine` field, native success must stop recording `failed: true` (AudioQueueActor.swift:389), the native path must compute its envelope so the portrait moves, and `UsageTracker` must persist or the spend gate steers blind. The genuine forks have narrowed to two: (a) whether the operator sees an engine *toggle* or only an invisible auto-route, gated on Priya's one-hour bake-off; and (b) product-or-personal-tool, which is Sir's sentence to write. The story pair and the design pair landed in the same place from opposite doors — the engine is plumbing, character is the visible choice — which tells me it's right.

## My top concession

I gave up insisting **persistence ships *before* the engine field.** In R1 and R2 I held that usage persistence is the true prerequisite — an honest counter beats a clean label on a blind gate. Sloan's counter holds: the `engine` field unblocks the *visible* deliverable (both toggles, the portrait fix, the history that stops lying), and persistence unblocks the *invisible* one (gate correctness). They're orthogonal. The cost of conceding: for the window between the two ships, we have a cleanly-labelled gate that is still amnesiac at launch — we'll *know* which engine spoke but still fail open on the cold-cache burst. I accept that because the gap is days, not sprints, and the ledger I'm about to defend renders the gap *visible* the moment it lands. Sequencing isn't abandoning the floor; it's pouring it in two pours.

## My line in the sand

**No one trusts the spend gate until spend is persisted and every decision is logged.** This is non-negotiable and it is *cheap* — one atomic-written sidecar (`cache/usage-state.json`) plus an append-only ledger row per decision: `{ts, engine, chars, decision: cached|bespoke|budget-canon|budget-fellthrough, health}`. Three specific things this kills, all confirmed in R2 against live code: the launch-amnesia re-baseline (UsageTracker is 100% RAM); the fail-open cold-cache spend hole at CaldwellHTTPServer.swift:1014–1019 where a blind gate falls through to full bespoke spend with zero trace; and the `Double.random` gate that can't be tested until the RNG is injected. And the privacy claim rides on the same ledger: if we tell users "free, local, no credits, nothing leaves your machine," that sentence is **only honest if the ledger proves which lines went to ElevenLabs and which stayed local.** A sovereignty claim you can't audit is marketing, not a guarantee. Ship the toggle, flip the default, rewrite the README lede — but not one word of "private" or "your spend is safe" until the ledger backs it. Telemetry that records the action but not the outcome is the bug I will not sign off on.

## My vote — the 3 principles we ship against

1. **Record before you manage.** Every utterance logs its engine, its character-cost, and its gate decision before any toggle or default is trusted. You cannot manage — or honestly market — what you don't measure.
2. **Honest failure over silent degradation.** The cold-cache fall-through, the un-muting config revert (`[String:String]` cast → defaults: unmuted, expletives ON), the `failed:true`-on-success — these are the real risk, not the happy path. Surface the seams; never let the product lie about its own state.
3. **One Caldwell, engine invisible — but only as far as the data is honest.** I'll back the story pair's "one voice, engine hidden" *because* the ledger makes the hidden engine accountable. Invisibility to the user, full visibility in the telemetry. That's the only version of the brand promise the data can stand behind.

## One open question R3 hasn't resolved

If the bake-off **wins** and the default flips to local-first, what is the persisted spend gate actually *for*? Its whole job was rationing a paid credit pool. Local-first makes ElevenLabs the rare premium exception — so does the gate shrink to "only consult usage when an EL line is explicitly requested," and does the ledger's `health` field become near-meaningless for most sessions? We agreed to build the observability floor regardless of the bake-off outcome, but nobody has specified what the gate *means* in the local-first world. I don't want to persist and ledger a gate that's about to be 90% dead weight without first knowing its post-flip shape.

— Han
