# R3 — Sloan Park, Principal Engineer (convergence)

## Shared diagnosis

The team has actually converged, and it's tighter than R1 suggested. Everyone — me, Han, Marcus, Yuki, Devi, Aja, Priya — independently arrived at the same load-bearing fact: the native `say` path is real, free, private, and already wired, but today it's crash-only code that *lies in the data* (records `failed: true` on a perfect native utterance, computes no lip-sync envelope, leaves the budget gate amnesiac and unauditable). So the engine-field refactor plus honest spend telemetry is **violent agreement** — it ships regardless of any other decision, because it's the floor everything else stands on. Two real forks survive into R4: (a) the local-first default is gated on Priya's one-hour bake-off, which the team has been quietly treating as already won; and (b) Aja/story-pair want the engine *invisible* (one Caldwell voice, no toggle) while design-pair want it *visible but framed as cost/privacy, not fidelity*. The team's centre of gravity: build the observable engine + ledger now, let the bake-off decide the default, and don't build the Settings toggle UI until the visible/invisible fork is broken by Sir.

## My top concession

In R1 I treated the `engine`-field refactor as *the* prerequisite and Han's usage persistence as "important but secondary." I give that up. The R2 engineering pair resolved it correctly: they're orthogonal, not ranked. The cost of my framing was real — it implied you could ship an observable engine onto an amnesiac gate and call the telemetry honest, when the cold-cache fail-open spend hole (CaldwellHTTPServer.swift:1014–1019) proves you can't. The engine field cleanly labels a gate that's still blind for the first network round-trip of every launch. The team answer — both land, engine field first because it unblocks the *visible* deliverable, persistence immediately after because it unblocks the gate's *correctness* — is simply more honest than my sequencing. I concede the ranking; I keep the claim that both are non-negotiable.

## My line in the sand

**Whatever default and visibility the team picks, the native path ships observable before it ships selectable.** `engine` as a first-class field on `AudioEntry`; native success recorded `failed: false` with its own history type; an envelope computed for the native path so the portrait moves; a startup voice probe surfaced on `/health`; and the per-decision spend ledger (including the `budget-fellthrough` case). Push me to flip the default to local — or to hide the engine entirely behind an auto-router — *before* that floor exists, and I walk. Not because the toggle is wrong, but because "one continuous Caldwell, engine invisible" (the story pair's entire WIN verdict) is a **lie the telemetry can't currently support**: a silent per-line engine switch with a frozen portrait and history that flags half the session red is not seamless, it's a debugging trap I'll be living in come December. The invisible-voice dream is *more* demanding of honest plumbing than the visible toggle, not less. No floor, no flip.

## My vote — the 3 principles we ship against

1. **Observable before selectable.** No engine becomes a user-facing choice (or a silent auto-route) until it's first-class in the data: honest success/failure, its own history type, a working portrait envelope, a health probe. Telemetry that records the action but not the outcome is a non-starter.
2. **Measure the engine that actually spoke.** Persist usage; ledger every spend decision with its engine, cost, and `health` at decision time. You cannot manage — or validate the bake-off in the wild — what you don't record.
3. **The bake-off gates the default, not the build.** The observability floor lands no matter what Daniel sounds like. The *default flip* waits on evidence. Don't price the renovation before the survey, but do pour the foundation now.

## One open question for R4

The story pair's WIN rests on **per-line invisible engine switching with no perceptible seam** — same voice, continuous moving portrait, even when ElevenLabs runs dry mid-session. I can make each engine individually honest and observable. I cannot yet promise the *transition* is imperceptible: Daniel and ElevenLabs are audibly different timbres, and a flip on a credit crunch will be heard. So the unresolved question is **scope of invisibility**: is "engine invisible" a per-line router (which I do not think I can make seamless), or is it "pick one engine per session and stay on it, the choice made once behind the curtain"? Those are very different builds, and the brand non-negotiable depends on which one we mean. Sir — and the bake-off — need to settle that before I touch the routing layer.

— Sloan
