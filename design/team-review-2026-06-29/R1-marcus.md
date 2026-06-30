# R1 — Marcus Holm, Product Designer (UI + craft)

## Verdict
The bones are stronger than I expected — the popover's material layering and the portrait system are genuinely considered — but the Settings tab reads like a form that apologises for its own existence, and the proposed voice-engine toggle risks becoming the ugliest pixel in an otherwise deliberate product.

## Top 3 findings

### 1. Visual hierarchy in SettingsView is inverted — the form leads with credentials, buries the identity

The ELEVENLABS API KEY block sits at the absolute top of the scroll. That's one of the least interesting things about Caldwell on any given day after initial setup. The persona toggle — CALDWELL'S MODE, the Polite/Potty-Mouth segmented control — is buried behind a Divider, after the Save button, after the status banner. That's backwards. The mode toggle is what Sir reaches for when he wants to change *who Caldwell is*. The API key is what he touches once and never again.

The visual weight argument is the same: the Polite/Potty-Mouth segmented control is the brand-expressible, character-carrying UI element in the whole panel. It should be above the fold. The API key and voice picker are technical infrastructure — push them down or behind a disclosure group. The hierarchy should read: Mode → Voice → Credentials → Usage → Updates. Right now it reads: Credentials → Save → Mode → Usage — which is the order a form library generates, not the order a person thinks.

This matters more than it sounds. When the proposed "Voice engine: ElevenLabs / Mac" toggle drops in, it will almost certainly get appended wherever seems easiest. If the panel stays in its current order, Sir will have four distinct concept-clusters above the fold with no clear reading sequence. That's the card-layout trap — row after row with no primary axis.

### 2. The proposed voice-tier toggle needs its own visual grammar — it cannot be a third segmented control

The panel currently has one segmented control: the Polite/Potty-Mouth picker. Add ElevenLabs/Mac-voice as a second segmented control and you've got two identically-styled pickers with no visual distinction between "who is Caldwell" and "how does he speak technically." They'll read as the same category of choice. They aren't.

Mode is *character*. Engine is *infrastructure*. Those are different conceptual weights and the UI should express it. My instinct: the engine choice wants a toggle-with-caption layout — a `Toggle` (the standard macOS toggle switch, not segmented) for "Use ElevenLabs" with the caption carrying the credit/fallback note beneath it. Toggle on = ElevenLabs is active, quota badge visible nearby. Toggle off = Daniel Enhanced, no credits consumed. The caption slots naturally: "Free — uses macOS Daniel Enhanced voice. Switches automatically when ElevenLabs quota is near limit." This is visually lighter than a segmented control, signals "this is a system setting, not a preference," and leaves the segmented grammar owned exclusively by the personality dimension.

The explanatory-note UX is important here. The credit-fallback behaviour — "if ElevenLabs runs low, automatically switches to Mac voice" — is the kind of thing that wants exactly one line of `caption2` beneath the toggle, not a modal or a callout box. The status banner pattern already in the panel is the right precedent: tinted, rounded, `caption`. Use it consistently or the panel starts mixing three different ways to say "this needs explanation."

### 3. The menubar glyph works; the statusline mark could do more

`person.bust` / `person.bust.fill` for muted/active is a considered decision and I'd leave it alone — the comment in CaldwellDashboardApp.swift documents the reasoning clearly (muted speaker.slash.fill was camouflage). The glyph at this size doesn't have room for more nuance and shouldn't try.

The statusline is a different surface. Right now `◆ Caldwell` and `⊘ Caldwell` are the only two states it expresses visually. Given that we're introducing a voice-engine axis — ElevenLabs vs. Mac vs. muted — the mark has a natural third state: speaking locally. The unicode vocabulary already supports this: `◇ Caldwell` (outline diamond) could mean "speaking but no credits spent," sitting between the filled ◆ (ElevenLabs active) and ⊘ (muted). Three glyphs, one axis, no label change needed. This would be a two-line edit to statusline.sh and would make the engine state legible at-a-glance without opening the popover.

The quip array is thin — 10 polite, 5 cheeky. The minute-bucketed rotation means Sir will see the same quip every 10 minutes for the rest of the session. At 16 items cycling on a 60-minute clock, any given session hits 3-4 distinct quips. Either ship 30+ quips or shift the index from `%M` (minute-of-hour) to something session-local and random. The pool is also entirely register-neutral; the potty-mode branch just merges the two arrays. The statusline already checks the config flag — the potty quips should be *distinct in register*, not just additions. Even two or three lines with genuine profanity in the rotation would make the Potty-Mouth mode feel consistent end to end.

## The single thing I'd ship to raise the craft

Reorder SettingsView: Mode → Voice → Credentials (collapsed DisclosureGroup, defaults closed) → Usage → Updates. One afternoon, no new APIs, no new components. The panel immediately reads as a product that knows what it's for, not a form that was built top-down from "what fields does the server accept?" The persona control above the fold is also the moment a new user grins — it shouldn't be below the fold on a 520px panel.

## What I'd defer as not my call

Whether Daniel Enhanced is *actually* indistinguishable from ElevenLabs in the butler register is a listen-and-decide call, not a design call — I can't answer that from Swift source. The default engine choice (ElevenLabs-first vs. Mac-first) and whether the toggle is opt-in or opt-out depend on the credit-spend philosophy and what Sloan says the fallback plumbing can actually guarantee. I'd also defer any portrait illustration changes — the three-frame lip-sync system (closed/slight/open) is doing real work and the aurora halo on the floating panel is above-average for a macOS menu-bar app; I wouldn't touch those without a specific complaint.

## One question for another persona

For UX (Yuki): the floating portrait auto-hides when the queue empties, but there's no documented *show* trigger in the code other than the queue becoming active. Is there a deliberate design intention for the transition timing — should it feel like Caldwell stepping into frame, or is the entry animation incidental? The `offset(y: sin(time * 1.1) * 2.5)` bob is continuous and pleasant, but the appear/disappear needs the same intentionality or the portrait will feel like a loading spinner rather than a character entrance.

— Marcus
