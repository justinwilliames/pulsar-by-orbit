# R2 — Story Pair (Nebula 🎨 + Echo 🩵)
**Brand × Activation cross-reference · Pulsar · pulsar-drones · 2026-07-01**

> The unifying claim: the rename crit and the drone-invisibility crit are **the same failure at two layers** — a first-timer meets a mis-named, swearing bot (brand layer) *and* never sees the headline feature that justifies the download (activation layer). Neither drone's fix works without the other's.

---

## Where we agree

**Nebula:** The first impression is off-brand and the headline move is missing — same wound Echo found, just measured with a different ruler. My "finish the rename + default Polite" and Echo's "wire the drones + tell the story" are two ends of one broken first-run.

**Echo:** Agreed, and the funnel proves it. Brand polish on an invisible feature is lipstick on a ghost — if the drones never fire, my activation fixes have nothing to activate. Nebula's identity work is the *reason to stay*; my wiring is the *thing to stay for*. Both, or neither.

**Both:** First-run is the whole game. This is a menu-bar app a stranger installs, forgets about, and judges on one moment — the first completed turn. Get that wrong and there's no second session to recover in.

## Where we fight

**Nebula:** Echo wants to ship a first-run banner + tooltips to explain the drones. Careful — explanatory chrome is a confession that the design isn't self-evident. If we need a paragraph to explain why there are six robots, the *visual* has failed. Fix the legibility (the pulse, the colour wheel, one drone stepping to centre) so it narrates itself; use copy as a floor, not a crutch.

**Echo:** Disagree on sequence, not substance. Self-evidence is the destination; a one-line prime is the on-ramp while we get there. "When Claude spawns sub-agents, they orbit as drones" costs one sentence and converts the confused into the delighted *today*. I'll happily delete the copy the day the motion carries it — but shipping silent-and-mysterious loses the user before the design ever earns its keep.

**Unresolved for the room:** does the drone swap need words at launch (Echo: yes, as a floor) or does words-at-launch signal a design we should fix first (Nebula: yes, fix the move)? Both agree the *pulse* + centre-step motion is the real answer; we split on whether to ship copy in the meantime.

---

## Definitive de-duplicated brand+activation fix list
*Ordered by first-impression impact — what a stranger hits first, worst-first.*

1. **[crit] install — drone hooks omitted from the one installer users run.** `scripts/install-hooks.sh` has `grep -c subagent = 0` (verified); only the in-app button wires SubagentStart/Stop. Add the two hooks additively to `install-hooks.sh`. *Without this the entire brand+activation story below is moot — the feature never fires.*
2. **[crit] persona — expletive default is split-brain and lands on swearing.** SKILL.md:3,33 declare **"Potty Mouth (default, `expletives_enabled: true`)"**; the live daemon returns `true`; the Swift read-fallback is `?? false` (Polite). A fresh user can meet heavy profanity before opting in. Make Polite the single authored default across SKILL.md **and** the daemon's persisted default; Potty Mouth becomes the opt-in.
3. **[crit] brand — the About card introduces the product as the wrong character.** AboutView.swift:32 reads "Speaks bespoke lines as **Caldwell**" (verified). One-word fix: → "as Pulsar." The one screen a newcomer reads must not name the dead brand.
4. **[high] activation — no "voice is live" confirmation anywhere in first-run.** Silent success is indistinguishable from silent failure across six fragile steps. Add a first-run popover banner: "Pulsar is running. Install the Claude Code skill to hear it" → green tick on first `/speak`.
5. **[high] positioning — the app never states why it exists.** The README's excellent one-liner never reaches the popover. Put "Your AI tells you when it's done. Stop watching the screen." under the Pulsar header, visible on first click.
6. **[high] brand — process/target/module still `CaldwellDashboard`.** Binary, bundle, module leak the old name in Activity Monitor / crash reports. Rename the target; alias `CALDWELL_*` env keys for back-compat.
7. **[high] drone narrative — zero in-product explanation of the swarm.** One line of micro-copy: "Sub-agents orbit as drones — each steps up when it speaks." (Nebula: floor only; fix the motion so this becomes deletable.)
8. **[med] signature — no move that is *only* Pulsar.** Make the **pulse** literal: rim/core light throbs on a heartbeat idle, syncs brightness to speech. The one move the name promises; drones inherit a dimmer version.
9. **[med] colour legibility — Sentinel/Atlas/Echo crowd the cyan-blue-teal wedge.** Push Atlas off-blue (violet or bronze-slate) so six drones read as six hues.

---

## The unified 60-second first-run story

**What SHOULD happen (0–60s after first launch):**
1. **0–5s — "I know what this is."** Popover opens; header carries the one-liner ("Your AI tells you when it's done"). The name everywhere is Pulsar. Identity is coherent and self-evident.
2. **5–20s — "I know how to turn it on, and I can tell it worked."** A first-run banner names the one missing step (install the skill), with a copy-paste command and a green tick the instant the daemon gets its first call. Success is *confirmed*, not inferred.
3. **20–60s — "Whoa — and it does *that*?"** First real Claude turn completes; a clean, **Polite** bespoke line fires. On an agentic run, drones orbit and one pulses to centre as it speaks — legible, colour-distinct, self-narrating. The wow lands on purpose.

**What HAPPENS today:**
1. Header is bare; About names **Caldwell**; the authored default is **Potty Mouth** — first impression is a mis-named bot that may swear at a stranger.
2. No confirmation exists anywhere. Six silent failure points; success and failure sound identical (silence).
3. The drones never fire — `install-hooks.sh` omits the hooks — so the headline move is invisible to every documented install. The one payoff that would earn a second session doesn't happen.

Three moments, three breaks. The stranger meets the wrong name, can't tell if it works, and never sees why it's special.

---

## One compound finding (needs both lenses)

**The default persona is an activation lever, not just a brand choice — and it's currently set against both.** Potty-Mouth-by-default (SKILL.md) is Nebula's brand crit (off-promise first impression: "hype-man," not "ambush") *and* Echo's activation crit (a cautious first-timer — the PM, the designer, the junior who heard about it — hears profanity before consent and closes the lid; that's a churn event at second zero). The split-brain default (`true` in the skill/daemon, `?? false` in the Swift read) means the *authored intent* the model follows is swearing, while the *toggle* claims Polite — so nobody's actually deciding. Fix requires both lenses: brand sets Polite as the on-promise greeter, growth confirms Polite maximises first-run survival, and one canonical default replaces the split. Potty Mouth stays as the delightful opt-in it was always meant to be.

---

*— Nebula 🎨 "The pulse is the one move only this product makes. Ship it and the swarm stops needing a caption."*
*— Echo 🩵 "Wire the drones, confirm the voice, greet them Polite. Three fixes and the first 60 seconds stops leaking users."*
