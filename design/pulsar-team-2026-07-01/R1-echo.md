# R1 — Echo (Growth / Positioning / Activation lens)
**Pulsar · pulsar-drones branch · 2026-07-01**

> "Who is this for and what changes after they use it?"

---

## Verdict

The core value prop is real and ownable — *"your AI talks back so you stop babysitting the screen"* — but the activation path has six silent failure points between download and first "wow," and the drone swarm ships with zero narrative: a new user sees coloured robots they were never told to expect, doing a job that was never explained to them.

---

## Findings

**[SEV crit] Activation — the "wow" requires six stars to align before a new user hears a single word**

WHY: Map the critical path: (1) download + Gatekeeper clear, (2) install skill symlink, (3) run install-hooks.sh, (4) start a new Claude Code session, (5) Pulsar app must be running, (6) daemon health check must pass. Any one of steps 1–5 failing produces total silence with no error, no feedback, no explanation. A user who skips step 2 (the skill) never gets model-composed bespoke lines — only the Stop-hook canon fallback, which fires a generic cached phrase that sounds like a broken record. A user who skips step 3 (hooks) gets nothing at all. There is no "voice is active" confirmation anywhere in the first-run experience. The user can only discover it worked by waiting for Claude to finish a turn — and then hoping the daemon was up.

FIX: Add a one-time first-run banner in the menu-bar popover: "Pulsar is running. To hear it speak, install the Claude Code skill" — with a copy-paste command and a green tick once the daemon gets its first `/speak` call.

---

**[SEV high] Positioning — the one-sentence value prop is buried under a feature list**

WHY: The README opens with: *"Pulsar is a voice companion that lives in your menu bar and tells you — out loud — the moment your code is done, so you stop babysitting the screen."* That's excellent — but it's in the README, which most downloaders from get.yourorbit.team never read. The app itself (popover, floating portrait, first-run screen) says nothing about *why* this exists. The menu-bar icon appears. The Settings tab asks for an ElevenLabs API key. Nothing on screen answers the question a new user is silently asking: "what does this do and why do I want it?" The app's UI has no tagline, no onboarding moment, no "here's what just happened" context.

FIX: Add the one-line value prop ("Your AI tells you when it's done. Stop watching the screen.") as a subtitle under the Pulsar header in the popover's History tab — visible from the first click on the menu-bar icon.

---

**[SEV high] Drone feature — zero discoverability, zero narrative, zero story for a new user**

WHY: Drones appear when sub-agents fire AND the hooks are wired AND the app is running AND the agent is categorised — four conditions a new user has no reason to know about. The feature has no documentation in the popover, no tooltip, no first-run explanation. If a user somehow sees a drone orbit, they have no idea: (a) what it is, (b) why there are multiple "Pulsar" heads, (c) what the colour coding means, (d) why one stepped to centre. The name card (as Devi flagged: 9pt, unreadable) is the only in-product "story" hook and it fails at that size. A feature the user can't narrate to a friend isn't a feature — it's a curiosity.

FIX: Add a single tooltip or micro-copy in the popover: "When Claude spawns sub-agents, they appear as drones — each orbits until it speaks, then steps up." One sentence, anywhere visible.

---

**[SEV high] Retention — the only loop is "Claude finishes something" — and most users won't notice for a week**

WHY: The retention mechanic is: user runs Claude Code → Claude completes turn → voice fires → user feels informed and stays at task. That's a real loop. But it only closes if the user (a) has multi-minute tasks where screen-watching is the actual pain, and (b) makes the association between the voice and feeling productive. Most new users will have short turns, hear a generic canon ping ("Sorted."), and dismiss it as a notification sound. The feature's value is highest on long agentic runs — which is also when the drone swarm matters most — but nothing in the onboarding directs users toward that use case. They install it for short turns, underwhelm, churn.

FIX: In the popover history tab, surface a "best used for" note: "Pulsar shines on long agentic sessions — kick off a task, walk away, let it tell you when to look." Primes the right mental model before the user has a chance to form the wrong one.

---

**[SEV med] Drone feature — "daily useful signal" vs "demo toy" — the product doesn't make the case**

WHY: The drone swarm is visually premium and genuinely useful for a heavy Claude Code user running parallel sub-agents. But right now the only way to trigger drones in practice is to already be running multi-agent sessions — meaning the people most likely to value drones are power users who discover the feature by accident. Casual users will never see it. The hooks aren't even wired by default (as Priya/Sentinel confirmed — SubagentStart/Stop don't reference the drone scripts). So: the most shareable visual feature of the whole product is invisible to 95% of installs.

FIX: Wire SubagentStart/Stop into install-hooks.sh (the one installer that runs) as the immediate unlock. Until then, the drone swarm is a design artefact, not a shipped feature.

---

**[SEV low] Setup friction — Gatekeeper quarantine step is a trust-killer for cautious users**

WHY: Step 3 of install requires the user to run `xattr -dr com.apple.quarantine "/Applications/Pulsar.app"` in Terminal. For a developer audience this is fine. For anyone less technical — a PM, a designer, a junior who heard about it — this is the moment they close the README. The unsigned app + manual Terminal command is a legitimate trust gap for a product whose value prop is "let this run on your machine and listen to your coding sessions."

FIX: Either pursue Apple notarisation (proper fix, not tonight's problem) or acknowledge the trust gap directly in the README step: "This is an unsigned open-source app — you can inspect every line at [repo]. The quarantine flag just means macOS hasn't seen it before."

---

## Single Highest-Priority Fix

**Wire the drone hooks into install-hooks.sh and add a 1-sentence in-popover explanation.** This is the unlock for everything. Right now the headline visual feature — the entire differentiator against a basic TTS notification — silently doesn't fire for any install that ran install-hooks.sh (which is every install). Adding SubagentStart/Stop to the installer costs 8 lines. Adding "drones appear when sub-agents run" to the popover costs 1 sentence. Without both, the drone swarm is a screenshot, not a product.

---

## Question for another drone

For **Voyager** (data/backend): is there any telemetry on what percentage of sessions that install Pulsar actually get the voice to fire on their first session? I want to know how wide the silent-failure gap is in practice before prioritising which activation step to instrument first. If 60% of users hear nothing in session one, that's an emergency. If it's 20%, it's a polish queue.

---

*— Echo, teal drone, growth lens. Features without a story are just coloured pixels.*
