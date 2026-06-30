# R2 — Priya Iyer, Chief of Staff / Ops — Synthesis

## What the team is collectively missing

### The unspoken assumption everyone is making

**That the bake-off has already been won.** Read the room: Sloan plumbs Mac-voice into a first-class engine, Han logs which engine spoke, Marcus designs the toggle's grammar, Yuki gives it a home in Settings, Devi rewrites the README around "zero-config Mac voice," Aja debates whether the engine should be visible at all. Every one of those is *downstream of a question nobody has answered*: **does Daniel Enhanced actually hold the Caldwell character on a Tier 3 line in Potty mode?** The team has quietly promoted "a free local voice now rivals ElevenLabs" from a hypothesis to a settled fact, and is now doing the interior decorating of a house whose foundation is untested. If Daniel reads flat on `[dry]`/`[deadpan]`, six of these seven diagnoses are partially void. We are pricing the renovation before the survey.

Second, quieter assumption: **that more configurability is the same as more product.** Three toggles, each crossed with the Polite/Potty axis, is a combinatorial test matrix landing on a single-maintainer, unsigned, fork-of-upstream codebase with zero install telemetry. Nobody has said out loud that config is a *liability* you take on, not a feature you ship.

### The one decision that unblocks the most downstream work

**Run the one-hour voice bake-off and decide, in one sentence, whether Caldwell is local-voice-first or ElevenLabs-first.** That single call cascades into nearly everything:

- If Daniel **wins** → free-path becomes the headline (Devi's README pivot goes live), the engine is invisible-by-default (Aja's "one voice, no toggle" wins over Marcus's toggle grammar), Sloan's spend-cap/phrase-cache machinery becomes *partly dead weight* to be pruned not extended, and the macOS-26 narrowing becomes a deliberate, defensible trade.
- If Daniel **loses** → ElevenLabs stays load-bearing, the toggle becomes a genuine fallback affordance (Marcus/Yuki design it as such), and the macOS-26 bet is correctly *not* taken.

**Cost of leaving it undecided:** every subsequent review round re-litigates the same fork. You build a toggle between two engines before proving both carry the character — and if one doesn't, the toggle was never the right object. Indecision here doesn't preserve optionality; it *taxes every other workstream* with a branch it can't resolve. This is a one-hour test gating roughly forty hours of downstream build. That ratio is the whole argument.

### The dependency order — critical path

```
[1] BAKE-OFF (1hr)          [2] POSITIONING SENTENCE (15min)
 Daniel vs EL, same 3 lines  "Caldwell is X for Y" — product or
 (T0/T2/T3+tag), Potty mode   personal tool? Signing on/off?
        │                            │
        └──────────────┬─────────────┘
                       ▼
            [3] DEFAULT DECISION  ← Sir's call, needs [1]+[2]
            local-first or EL-first; engine visible or hidden
                       │
        ┌──────────────┼───────────────────────┐
        ▼              ▼                         ▼
 [4] OBSERVABILITY  [5] ENGINE FIELD        [6] PERSIST USAGE
 Han's usage        Sloan's `engine` on     Han's sidecar +
 sidecar + ledger   AudioEntry; fix the     ledger (kills launch
 (engine breakdown) failed:true-on-success  amnesia spend hole)
        │           bug + install probe          │
        └──────────────┬──────────────────────────┘
                       ▼
            [7] SETTINGS IA RESTRUCTURE
            Yuki/Marcus: Mode → Voice → Creds → Usage
                       │
                       ▼
            [8] TOGGLE UI (only if [3] = visible engine)
```

The load-bearing rule: **[1] and [2] gate [3]; [3] gates the shape of everything below it.** [4]/[5]/[6] are the observability/data floor — they are *prerequisite to measuring whether the bake-off result holds in the wild*, so they should land regardless of [3]'s outcome. The toggle UI [8] is the *last* thing, not the first, and may not happen at all.

### The risks nobody is pricing

- **Bus factor is total and the proposal *adds* to it.** Four layers (Swift app, bash hooks, daemon, skill contract), one human, fork of `tomc98/speak` that will drift. Three toggles is three more state permutations to test and support forever. You don't add config to an unmaintained product; you add it to a maintained one.
- **macOS-26-only is a silent repositioning.** Daniel Enhanced narrows the audience from "anyone on Sonoma+ with a key" to "newest-OS-only, no key." The README still says macOS 14+. The accessibility win and the audience-narrowing are the *same lever* — and it's filed under "win," not "trade." Worse: betting the headline feature on a brand-new OS API surface that's one point-release from breaking, with no fallback if it regresses.
- **Config integrity is one bad hand-edit from un-muting itself** (Han: `config.json` cast fails → silent revert to unmuted/expletives-ON). That's a meeting-blast-radius bug sitting *under* all the new toggles we want to add.

### Violent agreement (just DO it) vs genuinely forked (Sir's call)

**Agreement — ship without further debate:**
- The native voice path should become a **first-class, observable engine**, not a crash-only fallback (Sloan, Han, Devi, Marcus all independently).
- **Fix the data lies**: `failed: true` on native success, no engine breakdown, RAM-only usage that dies at launch. (Sloan + Han, same target.)
- **Settings IA is inverted** — lead with Character/Mode, not credentials. (Yuki *and* Marcus reached identical orders.)
- The free path **changes the funnel** and the README lede should lead with the behaviour-change, not the mechanism. (Devi, with no dissent.)

**Genuinely forked — needs Sir:**
- **Is the engine visible to the operator at all?** Aja: one invisible voice, no toggle, ever. Marcus/Yuki: a toggle, designed with care. These are mutually exclusive product philosophies — you cannot do both. This is *the* creative-vs-UX deadlock and only Sir breaks it.
- **Product or shared personal tool?** Drives signing, the `xattr` cliff, support burden — Priya R1's sentence. Unanswered.

### Scope creep — queue for a separate pass

1. **Message-style (cached↔bespoke) toggle.** Polish on a product with no confirmed second user. Defer behind positioning.
2. **Statusline third glyph / quip-pool expansion** (Marcus). Genuinely nice, genuinely not this pass — it's craft on a surface that isn't on the critical path.
3. **Gatekeeper-friendly install / code-signing** (Yuki's question to eng). Real and important, but it's a *consequence* of the product-or-not decision, not a parallel workstream. Queue it to fire the moment [2] resolves to "product."

Don't let any of these three ride in on the back of the bake-off. They're a separate sprint.

Priya
