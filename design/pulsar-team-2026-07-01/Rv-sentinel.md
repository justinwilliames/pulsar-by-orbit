# Sentinel — Round 2 Verification (engineering fixes, branch pulsar-fixes)

Base: 18b81a4 → HEAD. Verdict per fix below.

## 1. Temp-AIFF leak — PASS
`discardResolved(id:)` unlinks the temp under NSTemporaryDirectory and clears `failedIds`. Every drop path is covered:
- **purge/stale**: `purgeStaleWaiters` calls `readyContinuations.removeValue` + `discardResolved` per dropped entry (AudioQueueActor.swift:406-407).
- **timeout**: worker consumes `resolvedURLs.removeValue` at :593 and plays it, OR falls to native fallback; a URL landing AFTER the worker moved past self-cleans in `markReady` orphan guard (:421-427). No leak.
- **played**: `playEntry` deletes the temp AIFF post-play, tmpDir-guarded, after retaining a history copy (:798-800).
- **orphan late markReady**: guarded, unlinked (:421-427).
All deletions are prefix-guarded to NSTemporaryDirectory, so cache/history mp3s are never touched. No remaining leak path found.

## 2. Immortal-ghost removal + TTL 600 — PASS (trade-off acceptable)
`touchInFlightDrones` is fully removed from both the actor and the only call site (handleSpeak now calls `promoteInFlightDrone`). Speech no longer refreshes `lastSeen`. Trade-off: a legit silent agent >10min with a LOST SubagentStop is now swept early. But the normal Stop path is reliable + retried (fix 6), so the 600s backstop only bites a genuinely-dropped Stop — and even then only a rare >10min silent runner. Correct call: kills the immortal ghost (the real, recurring bug) at the cost of a rare, self-healing false-evict. Accept.

## 3. SSE bounded buffer — PASS
`AsyncStream(bufferingPolicy: .bufferingNewest(64))` is the correct API; drops oldest under backpressure. Right semantics for state-replacing UI events (voice_active/drones/settings) where newest wins.

## 4. terminationHandler continuation — PASS
Handler set before `run()`; exactly-once resume. Success → handler fires once. Throw → handler cleared (`terminationHandler = nil`) then `cont.resume(throwing:)` — no double-resume, no leak. Correct.

## 5. Claim-based promoteInFlightDrone — PASS
Actor-isolated (`func` on the actor) → serialised, safe under concurrent /speak. Returns false (no broadcast) when empty/"pulsar", when a drone of that category already exists (no dupe), or when no generic drone to claim → broadcasts only on real mutation. At most one promotion/call; picks most-recent generic. No wrong/re-promotion.

## 6. Reliable subagent-stop — PASS
3-attempt curl retry with back-off, `--max-time 4`; always `exit 0`. Failure appended to `$PULSAR_HOOK_LOG` (default ~/.claude/pulsar-hook-failures.log), all mkdir/date wrapped in `|| true`. Never blocks Claude Code. Sound.

## 7. HOOK COPY SYNC — PASS (no drift)
`diff scripts/subagent-{start,stop}.sh macos/.../claude-integration/scripts/` → IDENTICAL both.
`install-hooks.sh`/`uninstall-hooks.sh` are absent from the bundle — **this is correct, not drift**: the app installs via Swift `ClaudeIntegrationInstaller.swift`, which mirrors the script and DOES wire both drone hooks (:192-193) and copies only the two drone `.sh` files (:80). Bundle carries the runtime hooks; the shell installer is the manual/dev path only. No stale bundled hook ships.

## Return
All 7: PASS. No [BLOCKER], no [BUG]. Regression scan clean.
