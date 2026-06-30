# R1 — Sloan Park, Principal Engineer

## Verdict
The native `say` path is a real free-tier voice engine, but right now it's a crash-only code path nobody can choose, observe, or trust — ship the toggle, but fix the silent failure modes underneath it first.

## Top 3 findings (engineering / failure-modes / observability)

**1. The Mac-voice path is reachable only via failure, and its failure modes are invisible.**
`speakNative()` (AudioQueueActor.swift:345) is dead-end code: it fires *only* when `entry.fetchFailed || audioURL == nil` (playEntry, :379). The proposed toggle wants this as a first-class engine, but today there is no field on `AudioEntry` to request it — you'd be promoting a fallback to a primary with zero plumbing. Worse, when it runs it's unobservable in the way that matters: a failed `say` launch is logged and swallowed (:372–374), and **history is recorded with `failed: true` even when Daniel spoke the line perfectly** (:389). So the moment Mac-voice becomes a normal engine, every successful local utterance is mislabelled a failure in `/history`, `/events`, and the lip-sync envelope (envelope is never computed on the native path — the portrait won't move). Six months from now, "why is half my history red?" is an afternoon of debugging that better data modelling kills today. There's also no verification the requested voice is *installed* — `say -v Daniel` on a box without the enhanced voice exits non-zero into the swallow, and Caldwell goes silent with no diagnostic. The game-changer voice has no health check.

**2. The budget gate is non-deterministic and effectively untestable.**
`shouldSpeakBespoke()` (CaldwellHTTPServer.swift:809) ends in `Double.random(in: 0..<1) < prob`. A probabilistic spend gate cannot be unit-tested without injecting the RNG, and right now it isn't injected — so the single most expensive decision in the system (spend ElevenLabs credit vs. fall back) has no deterministic test and no emitted signal saying *why* it throttled. The `reason: "budget-canon"` string in the response is the only breadcrumb, and it's not surfaced anywhere durable. Once Mac-voice exists, this whole gate is half-obsolete anyway: the right throttle isn't "downgrade to a cached canon ping," it's "downgrade to the *free local voice* speaking the actual bespoke line." The gate and the new engine need to be designed together or they'll fight.

**3. Process and continuation lifecycle is racy under the new concurrency it invites.**
`currentProcess` is set/cleared across `speakNative` and `playEntry` with no guard that a `--skip` arriving between `process.run()` and the `currentProcess =` assignment terminates the *right* process (AudioQueueActor.swift:363, :425). With one engine and a depth-1 queue this is mostly survivable; add a synchronous-feeling local engine that returns far faster than a network fetch and you change the timing profile that's currently masking it. Separately, the worker's fetch watchdog (:289) and the play-deadline kill task (:439) both reach into `process.isRunning`/`terminate()` from detached tasks — fine today, a debugging nightmare the first time two of them race on a reused `currentProcess`. None of this is exercised by a failure-mode test, which is exactly my pet hate: the suite (if any) proves the happy path and ignores the seams.

## The single thing I'd ship to fix the biggest problem
Make Mac-voice a first-class, observable engine *before* exposing the toggle: add an `engine` field to `AudioEntry` (`.elevenlabs` / `.native`), route `playEntry` on it, and record native success as `failed: false` with its own history `type` ("native"). Add a one-time startup probe — `say -v "<voice>" -o /dev/null ""` or parse `say -v '?'` — that verifies the enhanced voice is installed and emits the result on `/health` and `/settings`. That single change turns the proposed setting from "secretly swap to a path that lies in the logs" into "an engine choice Sir can see working." Without it, the toggle ships a debuggability regression.

## What I'd defer as not my call
The *defaults* (ElevenLabs-first vs. Mac-first) and whether cached pings stay ON by default are spend/brand/UX decisions, not engineering ones — I'll implement whatever's chosen. Likewise the persona-quality question of whether Daniel Enhanced is "good enough" to be the everyday voice is a taste call for creative. And the measured-rate value (`-r`) is a voice-feel tuning knob, not an engineering constant — give me a number, I'll wire it.

## One question for another persona
For UX (Yuki): if the budget gate silently downgrades a bespoke line to a generic cached ping, **does Sir need to know it happened** — a muted glyph state, a status-line hint — or is silent degradation the desired feel? The answer decides whether `reason: "budget-canon"` is a throwaway string or a first-class observable I need to thread through SSE.

— Sloan
