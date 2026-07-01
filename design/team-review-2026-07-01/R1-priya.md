# R1 — Priya Iyer (Chief of Staff / Ops)

**Lens:** ship-readiness, owners, the unspoken assumption. What's the blocker, and who owns it by Friday?

## Verdict
**Demo-ready, NOT ship-ready.** The render layer is gorgeous and the daemon endpoints are real — but the wire from a *real* sub-agent to a drone is not connected in the live config. Today this fires only when something POSTs the daemon by hand. Unattended, in a real session tonight, **zero drones appear.**

## Top 3 findings

**1. The SubagentStart/Stop hooks in live `settings.json` don't call the drone scripts. This is the blocker.**
`~/.claude/settings.json` lines 171–204 wire `SubagentStart`/`SubagentStop` — but only to `claudata/hook.mjs` (telemetry) and `log-delegation.sh` (ledger). The scripts that actually POST `/subagent/start` and `/subagent/stop` — `scripts/subagent-start.sh` / `subagent-stop.sh` — are **not referenced anywhere in the live config.** They're orphaned. Everything downstream (Swift server lines 170–185, DroneRegistry, the swap animation) is correct and waiting on input that never arrives. The "verified with simulated drones" demo was a direct POST; it bypassed the one link that's broken.

**2. Two installers disagree about whether drones get wired — nobody owns reconciling them.**
`scripts/install-hooks.sh` wires Stop/SessionStart/UserPromptSubmit voice hooks and **never adds SubagentStart/Stop** (see its own header, lines 6–98). The in-app `ClaudeIntegrationInstaller.swift` (lines 192–193) *does* register both drone hooks. So the feature works or doesn't depending on which installer last touched the file — and the live file shows neither drone script won. That's a silent config drift with no owner. Pick ONE installer as source of truth tonight.

**3. No identity contract between `agent_id` at spawn and `agent_id` at the speak/subtitle path — unverifiable end to end.**
`subagent-start.sh` resolves `agent_id` from `agent_id`/`agentId`/`session_id` (line 32). The active-speaker swap themes the bubble by matching that id. If Claude Code's SubagentStart payload field name differs from what `say.sh` sees at narration time, drones will spawn but **never take the centre seat** — they'll orbit mutely while Pulsar keeps talking. This has never been tested against a live payload, only synthetic JSON. It's the second hidden failure mode behind #1.

## Single highest-impact fix
**Add the two drone hooks to live `settings.json` and run one real sub-agent session end-to-end tonight.** Append `subagent-start.sh` to the existing `SubagentStart` array and `subagent-stop.sh` to `SubagentStop` (additive — leave `hook.mjs`/ledger untouched). Then spawn a *real* Explore agent and confirm: (a) an amber Voyager drone appears, (b) it swaps to centre + themes the bubble when it speaks, (c) it fades on stop. Capture the actual hook payload during that run to settle finding #3. Make `install-hooks.sh` the single installer that does this, so it never drifts again. **Owner: dev, tonight. Done = one unattended real session shows a drone, not a screenshot.**

## One question for another lens (Sloan / eng)
What is the **exact field name and lifecycle of `agent_id`** in Claude Code's real `SubagentStart` vs `SubagentStop` payloads — and does it match the id the narration/speak path uses to attribute a spoken line to a drone? If those three don't share one key, the swap silently no-ops even after the hooks are wired.
