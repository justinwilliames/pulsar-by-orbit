# R1 — Sloan Park (Principal Eng lens)

**Verdict:** The swap *looks* premium but rests on two independent state clocks and an N×60Hz render fan-out — it'll demo great tonight and become an undebuggable jitter/flicker ticket in three weeks at 4+ drones.

## Top 3 findings

**1. Two clocks drive the swap → race + colour/lip desync.** `FloatingHeadsView.activeDroneCategory` reads `playback.currentAgentCategory` (cleared on the *idle* event), while `orbitList`/`sortedDrones` read `inFlightDrones` (cleared on *SubagentStop*). The comment at lines 76–81 openly documents the gap: a drone holds centre after its sub-agent is already gone from `inFlightDrones`. Four signals — `currentVoice`, `currentAgentCategory`, `lipSync.amplitude`, `inFlightDrones` — update on different paths. When line B (different drone) starts before line A's linger ends, centre identity, `glowColor`, subtitle `activeColor` and the live amplitude can each flip on a different frame. That's the classic "worked Friday, flickers Monday, nobody remembers the ordering." Needs ONE derived speaker struct `{id, category, color, amplitude}` computed in the view model, single source of truth, so the view can't assemble an inconsistent frame.

**2. Render cost scales with drone count and is unbudgeted.** Every `PortraitView` owns a `TimelineView(.animation)` (~60Hz) *plus* an `onChange(of: timeline.date)` firing `advance()` — a `@State` write every tick (PortraitView.swift:99,149). `FloatingDronePortraitView` and `QueueBubbleView` wrap their *own* `TimelineView` on top (double-nested). Centre + 6 orbit + up to 5 queue bubbles = ~12 independent 60Hz loops, each doing crossfade math, blink RNG and a state mutation, with zero `drawingGroup()`/Metal compositing. On battery / external display this is a fan-spinner. No frame budget, no instrument.

**3. Orbit geometry collides past ~4.** Fixed arc 20°–160° (FloatingHeadsView.swift:22–23) at a single `orbitRadius 82`, `thumbnailSize 40`. During a swap Pulsar is *forced* into orbit (line 174), so worst case is 7 nodes on a 140° arc ≈ 20° apart — portraits visibly overlap. No radius growth, no angular-collision guard, no second ring. "Up to ~6 drones" is in the brief; the layout silently can't seat them.

## Single highest-impact fix
Collapse the speaker into one view-model-derived value. Add `var activeSpeaker: SpeakerSnapshot?` (id, category, color, amplitude) recomputed wherever any of the four inputs change, and have `centreOccupant`, `droneNameCard`, and `SubtitleBubbleView.activeColor` read *only* that. Kills the desync class, makes the swap atomic, and — critically — makes it debuggable: one value to log, one value to assert in a test. Ship tonight; it's a refactor, not a redesign.

## One question (for Yuki / UX)
When line B preempts line A mid-linger, what's the *intended* felt behaviour — does A finish its swap-out and B swap in (serialised, ~0.5s tax), or does B cut in immediately? That decision determines whether I serialise the state machine or hard-interrupt it, and it's currently undefined in code.
