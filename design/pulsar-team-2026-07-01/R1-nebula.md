# R1 — Nebula (Creative Direction: brand essence + narrative coherence)

## Verdict
The cast is finally distinct on the axes an engineer can list (hue, voice, bob) — but the brand still *says* one thing (a self-aware, mostly-lovable robot hype-man called Pulsar) while the code, the default persona, and the About card *ship* another (a swearing bot called Caldwell). The identity is half-renamed and its first impression is off-brand.

## Findings

**[SEV crit] AboutView.swift:32 + config default — the product introduces itself as the wrong character, swearing.**
The one screen a new user reads says "Speaks bespoke lines as **Caldwell**" — the old name, in the brand's own About box. Worse, `expletives_enabled` defaults to **Potty Mouth ON** (SKILL.md + CaldwellConfig `CALDWELL_EXPLETIVES` default), so the very first line a stranger hears is heavy profanity, before they've opted in. That's not the "secretly-your-hype-man" promise — it's an ambush. FIX: rewrite the About line to "…bespoke lines as Pulsar," and default expletives OFF (Polite is the safe, on-brand first impression; Potty Mouth is a delightful opt-in, not the door greeter).

**[SEV crit] Info.plist:8 / Package.swift / whole target — the app is still named CaldwellDashboard everywhere the user can reach.**
BundleIdentifier is fixed (`team.yourorbit.Pulsar`), but `CFBundleName`/executable = `CaldwellDashboard`, the SwiftPM target, `CaldwellHTTPServer`, `CaldwellConfig`, all `CALDWELL_*` config keys, and the history voice-label fallback (`"Caldwell"`, HTTPServer.swift:615) still carry the dead name. A user who opens Activity Monitor, the app folder, or a crash report sees "Caldwell," not "Pulsar." A brand that leaks its own former name at every seam isn't launched, it's mid-rename. FIX: rename the target/executable to Pulsar and the process/label strings; the `CALDWELL_*` env keys can alias for back-compat but the user-visible ones must read Pulsar.

**[SEV high] DroneRegistry.swift:77,85 — Sentinel (azure) and Atlas (slate-blue) collide at 52px.**
Sentinel `(0.42,0.72,0.92)` and Atlas `(0.50,0.55,0.80)` are both mid-blue; at a 52px thumbnail rim-glow, desaturated by the glow blur, they read as the same drone. Echo teal `(0.18,0.75,0.72)` sits close to Sentinel too — three of six occupy the cyan-blue-teal wedge. WHY: a six-body swarm needs six *hues around the wheel*, not four blues and a green. FIX: push Atlas off-blue entirely (a warm slate / bronze-grey, or violet) so the wheel reads amber–green–teal–azure–violet–magenta with even spacing.

**[SEV high] DroneRegistry.swift:85 — "atlas / generalist" is a junk drawer wearing a character costume.**
Every unknown category collapses to Atlas (the fallback in `voice`/`droneColor`/etc. is *Pulsar*, but any agent tagged `atlas` and every "general" spawn lands here), so Atlas is simultaneously a named character *and* the miscellaneous bin. A character that means "everything we didn't classify" means nothing — it has no lens, no signature, no line only it would say. WHY: it dilutes the ensemble; six specialists + one grab-bag reads as six specialists and a mistake. FIX: either give Atlas a real, ownable remit (ops/coordination — the one who *carries the load*, which the name already implies) and route only true generalist work to it, or drop it to 5 drones and let unknowns fall to Pulsar (which the code already does for colour/voice).

**[SEV med] DroneRegistry.swift:59-66 — voices are gendered by an *assumption* that fights the portraits.**
The registry hard-codes "assumed gender" per drone to allocate 3 male / 4 female macOS voices, but the allocation is driven by *which voices happen to be installed*, not by character. Nebula (artist, the magenta one) got Moira purely because "four female voices go to the four female characters." That's voice-casting by spreadsheet, not by soul — and it bakes a gender claim into a robot cast that visually reads as androgynous machines. WHY: the *character* should pick the voice; here the available-voice list picked the character's gender. FIX: cast voice to persona energy (Sentinel = clipped/precise, Voyager = gruff/wide, Nova = bright/fast) and stop asserting gender in comments — let the machines be machines.

**[SEV med] Whole system — there is no single move that is *only* Pulsar.**
The trade-places choreography (Aja R1, now partly built via MotionTrait) is the candidate, but nothing yet is *unmistakably this product*: the portraits are a generic "cute chibi headphone-robot" family (indistinguishable from a dozen AI mascots), the swarm is a speaker-carousel, and Pulsar's own pulse — the thing the *name* promises, a rhythmic light-pulse that beats when it speaks — is absent from the identity. WHY: a design system with a bible but no signature is a component library, not a brand. FIX: make the *pulse* literal and load-bearing — Pulsar's rim/core light throbs on a heartbeat while idle and syncs its brightness to speech amplitude; drones inherit a dimmer version. One move, named after the product, that no other mascot does.

**[SEV low] design/drones — source portraits shot at inconsistent crops.**
Masters split into tight badge-crops (voyager/sentinel/echo/nova, 1024²) vs full-body wide shots (atlas/nebula, 1254²). The *derived* mouth frames normalize to 362² so the live cast is fine — but the master set is an inconsistent reference and will reintroduce drift on the next re-render. FIX: re-crop all six masters to one framing spec (head-and-shoulders, identical headroom) so the source of truth is coherent.

## Single highest-priority fix
Finish the rename **and** flip the default persona to Polite. The crit isn't cosmetic: today a first-time user meets a swearing bot named Caldwell in a Pulsar-branded window. Ship the name (target, plist, About, process labels) and make Polite the default door-greeter with Potty Mouth as the opt-in. Everything else is polish on a product that currently fails its own first impression.

## Question for another drone
For **Atlas** — Sentinel (engineering): is `atlas` *actually* the code's catch-all sink, or does the fallback resolve to Pulsar for real spawns? If unknown categories genuinely land on Atlas anywhere in the pipeline, that's a brand+legibility bug; if they resolve to Pulsar, Atlas is safe to promote into a real ops character. I need the ground truth before recommending "give it a remit" vs "delete it."

— Nebula 🎨 *"What's the one move that's only ever this product? Right now: none. Make it the pulse."*
