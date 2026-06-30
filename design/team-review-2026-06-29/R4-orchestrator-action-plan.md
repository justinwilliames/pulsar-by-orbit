# Team Review Action Plan — Caldwell — 2026-06-29

Seven lenses, five rounds. The review converged faster and harder than a feature
review usually does, because everyone independently hit the same load-bearing
fact: **the free local macOS voice is real, private, already wired — and today
it's crash-only code that lies in the data.** That reframes Caldwell from "an
ElevenLabs toy with a fallback" into "a free, local, private butler with an
optional premium voice." The work is making the product tell that truth.

## The three principles the team ships against

1. **Observable before selectable / record before manage.** No engine becomes a
   user-facing choice or a silent auto-route until it is first-class in the data:
   an honest success flag, its own history type, a computed lip-sync envelope, a
   `/health` install probe, and a persisted per-utterance spend ledger. You
   cannot manage — or honestly market — what you don't measure. *(Sloan, Han)*
2. **Every silent state has a recovery path.** Muted, credits-exhausted,
   Daniel-not-installed, budget-downgraded — each produces a visible, in-context
   signal with a one-tap action. Silent failure at a cost or capability boundary
   is a dark pattern, not brand restraint. *(Yuki)*
3. **One identity; character is the choice, engine is plumbing.** One name, one
   face, one canon. The words "Daniel" and "ElevenLabs" never reach the operator
   as a *quality* tier. The operator controls persona (Polite/Potty) and, at
   most, cost/privacy — never "who Caldwell is." *(Aja, Marcus, Devi)*

## What the team agreed on

- **The observability floor ships first, unconditionally.** Engine field on
  `AudioEntry`, honest native playback, install probe, persisted spend ledger.
  It's not optional polish — it's the instrument that *reads* the bake-off and
  the only thing that makes a "free/private/no-credits" claim auditable.
- **The free local voice is the strategic centre, not a fallback.** Whatever the
  default ends up being, demoting the local path to a crash-handler is the
  mistake. It is the activation unlock (7-step setup → ~2 min, zero cost) and the
  privacy win (no text leaves the machine).
- **A labelled "ElevenLabs vs Mac voice" quality toggle is dead.** Six of seven
  reject exposing engine *names* as a fidelity choice — it dilutes the one-voice
  brand. (This is a direct, friendly push-back on the original spec; see Sir's
  call #1 for the surviving, softer form.)
- **Nothing below the default-decision is built until the bake-off runs.** One
  hour of testing gates ~40 hours of build. The team was quietly treating the
  bake-off as already won; it is not.
- **The pitch:** *"Caldwell is a butler who lives in your terminal and tells you,
  out loud, the moment your code is done — so you stop babysitting the screen.
  Free, two minutes, no account."*

## Shippable now (next 48 hours)

1. **Engine field + honest native playback.** Add `engine` to `AudioEntry`; route
   `playEntry` on it; native success records `failed: false` with its own history
   type and a computed envelope so the portrait animates. *Owner: Sloan (eng).
   ~½ day. Evidence: R2-engineering-pair; Sloan R1/R3 — native path currently
   logs `failed:true` on a perfect utterance (AudioQueueActor ~line 389).*
2. **Persisted spend ledger + close the cold-cache spend hole.** Atomic
   `usage-state.json` sidecar + append-only per-decision ledger (engine, chars,
   decision incl. `budget-fellthrough`, health). Seed the gate at launch so it
   stops failing *open*. *Owner: Han (data). ~1 day. Evidence: R2-engineering-pair
   — CaldwellHTTPServer.swift:1014 fails open on cold launch during the loudest
   ping burst, untracked.*
3. **Startup voice-install probe on `/health` + `/settings`.** Verify "Daniel
   (Enhanced)" is present; surface it. *Owner: Sloan. ~2 hrs. Evidence: Sloan
   R1/R3 — no health check today.*
4. **Persona (Polite/Potty) control above the fold.** Reorder `SettingsView` so
   Character is the first section. Unconditional, no dependency on any fork.
   *Owner: Marcus (UI). One afternoon. Evidence: Marcus R3 line-in-the-sand — the
   brand moment is currently buried below credential fields.*
5. **Run the one-hour bake-off.** Daniel Enhanced vs ElevenLabs, the same three
   canon lines, Potty mode, blind A/B. *Owner: Priya/Sir. 1 hr. Evidence: Priya
   R1/R2/R3 — the untested premise gating everything.*
6. **Fix the README platform claim.** It says macOS 14+, the app is 26-only.
   *Owner: Priya. 10 min. Evidence: Priya R1 — reach/honesty.*

## Queue for the week (after the bake-off + Sir's calls land)

1. **Settings IA restructure** — Character → Voice → Usage & Limits (auto-expands
   on warning/critical/exhausted) → Updates; credentials inside a collapsed
   disclosure. *Owner: Yuki + Marcus. ~1 day. Reconciled in R2-design-pair.*
2. **Recovery banners for every silent state** — exhausted→one-tap, Daniel-not-
   installed→guide to System Settings (the app can't download voices, only
   point), budget-downgraded, muted. *Owner: Yuki. ~1 day. Yuki R3 line.*
3. **README lede rewrite** — behaviour-first; free voice as the default
   onboarding path; ElevenLabs demoted to an "upgrade your voice" section. **Gate:
   the privacy/sovereignty language ships only after the audit ledger (#2 above)**
   — Han: "a claim you can't audit is marketing, not a guarantee." *Owner: Devi.
   ~½ day.*
4. **Robust `config.json` parsing** — a bad hand-edit currently silently reverts
   mute→off (a relative of the mute-drift seen in dev). *Owner: Han. ~2 hrs.*
5. **Message-style toggle (cached pings vs bespoke-only)** — the third proposed
   feature. Cheap once the engine floor + ledger exist; defer until then.
   *Owner: Sloan. ~½ day.*
6. **Canonise "Pushed, Sir."** — promote the catchphrase pool from "free
   fallback" to named house canon, surfaced as Caldwell's signature. *Owner: Aja.
   ~½ day.*

## Defer (with justification)

- **Product packaging / multi-machine distribution / open-source launch.**
  Defer until Sir answers "product or personal tool?" (call #3). Building
  distribution before the positioning decision is motion without direction.
- **Voice tuning beyond rate (`[[pbas]]` pitch, Siri voices).** Siri voices are
  walled off from `say`; `[[pbas]]` doesn't apply to enhanced voices; rate (`-r`)
  is the only lever that works on the voice we'd actually use. Not worth the
  effort until/unless the bake-off says timbre is the problem.
- **A second/alternate fallback voice beyond Daniel Enhanced.** One voice, one
  identity. Adding voices is the opposite of the brand principle.

## Sir's call needed

**1. Engine: invisible auto, or a visible cost/privacy control? (genuine
deadlock — decide *after* the bake-off.)**
The data model serves either; this is taste, not engineering.
- **A — Invisible / auto-route** (Aja, Devi, Marcus, story pair). One Caldwell;
  no engine UI. Default to local; ElevenLabs becomes a silent premium upgrade.
  *Wins:* maximum brand purity, simplest UX, cleanest free-first funnel. *Loses:*
  no explicit cost control; the audible voice-switch on fallback is unexplained.
- **B — Visible, framed as cost/privacy** (Yuki, Marcus-in-R2). A single Toggle —
  "Local & Private (free)" vs "Premium (uses credits)" — never the words
  "ElevenLabs/Daniel/quality." *Wins:* explicit cost + privacy control, a natural
  home for the install-status and recovery UI, fully honest. *Loses:* a sliver of
  purity; one more control on the panel.
- *This is the surviving form of your original request* (a visible ElevenLabs-vs-Mac
  toggle). The team's near-unanimous amendment: if it's visible at all, it must be
  **cost/privacy, not engine names or fidelity.**
- **CoS recommendation (Priya):** decide after the bake-off. If Daniel *loses*,
  the question half-dissolves — ElevenLabs stays primary, local is the honest
  fallback, and an explicit control (B) becomes more useful. If Daniel *wins*,
  invisible (A) is the stronger brand play. *Cost of waiting:* the Settings IA
  and recovery work (queue #1–2) can't finalise their top section until this is
  set — but the floor (ship-now #1–3) is unblocked regardless.

**2. Default voice: local-first or ElevenLabs-first? (gated on the bake-off.)**
- If Daniel Enhanced holds the Caldwell character on a Tier-3 Potty line →
  **local default**, ElevenLabs an opt-in upgrade (the funnel + privacy win).
- If it doesn't → **ElevenLabs stays default**, local stays the honest free
  fallback, and the repositioning narrows to "free fallback so you're never
  mute," not "free-first."
- *Cost of waiting:* README, Settings top section, and the whole funnel narrative
  branch on this one result. One hour of testing resolves it.

**3. Product, or personal daily-driver? (the unspoken undecided.)**
- The team built a product-grade critique of what may be a personal tool. You can
  **take the free-voice default win either way** — but distribution, macOS-26
  reach, onboarding polish, and the README's ambition all depend on the answer.
- **CoS recommendation:** write the one sentence now. "Personal tool that's
  shareable if friends ask" is a *legitimate, freeing* answer — it lets you ship
  the local-voice default and the floor, and defer all distribution work without
  guilt.

## Open questions surfaced in R3 (carried to R5)

- **The audible switch.** When ElevenLabs exhausts mid-session and Daniel takes
  over, the voice *changes*. Does "one identity" require a tiny "switching to the
  local voice, Sir" acknowledgement, or is a seamless single identity simply
  impossible across two engines — making honest disclosure the *only* brand-safe
  option? (engineering × brand)
- **Bake-off failure.** If Daniel can't be Caldwell, does "one identity" force
  picking ONE engine permanently rather than ever switching? (Aja/story)
- **Sovereignty timing.** Han holds that no "private/local" claim ships before the
  audit ledger. Agreed as a hard gate — flagging so it isn't quietly skipped when
  the README rewrite feels ready first.
