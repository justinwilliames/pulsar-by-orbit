# R1 — Atlas (UX / Behavior / Accessibility lens)

**Verdict:** The core model is coherent, but five concrete flows break in ways that make a first-time user feel like the app is doing nothing — and an existing user feel gaslit when mute/panel state quietly disagree.

---

## Bug List

### [SEV high] `AppDelegate.swift:98–103` / `DashboardViewModel.swift:52` — Mute kills the panel wake but no-one tells the user

**WHY:** When muted, `/speak` returns HTTP 200 with `{"muted": true}` — so `say.sh` exits 0 and Claude Code sees success. Meanwhile the floating head never appears (AppDelegate bails at the `floatingHeadEnabled` guard if it even gets that far, but it doesn't because `handleSpeak` returns early and never enqueues). There is no SSE event, no queue change, no `onPlaybackChanged` call. The app is visually silent and so is the daemon. The user has no idea whether: (a) voice is muted, (b) the app is down, (c) the hook never fired. The mute banner in `SettingsView.swift:301–306` only appears if the user opens Settings — it is invisible from the popover header (the header `muteToggle` shows "Muted" only after a settings load, which happens on popover open, so it IS visible there). However, a muted state that was set via `say.sh --mute` externally will not reflect in the menu-bar icon until the next SSE `settings` broadcast — which only fires on a `/settings POST`, not on every `/speak` muted-return. The icon never updates until the user opens the popover.

**FIX:** On every muted `/speak` response, broadcast a `settings` SSE event so the icon self-corrects immediately; and/or document this in the mute banner so the user understands the panel being absent is expected.

---

### [SEV high] `FloatingHeadsView.swift:270–287` / `AppDelegate.swift:42–46` — `showActiveAgents OFF` + drone speaking = panel wake with nothing visible

**WHY:** When `showActiveAgents` is off and a drone speaks, `participants` returns an empty list (lines 273–287: agents are hidden, drone is the speaker, no head is emitted). But the `/speak` call with an `agent` attribute still triggers `onPlaybackChanged(true)` via `recomputePanelVisibility`, so AppDelegate calls `panel.orderFrontRegardless()`. The panel opens and the user sees: a blank floating window. The caption is also suppressed (`captionSource` returns nil when agents hidden and `isDrone` is true, line 374–379). The user sees a floating empty rectangle hovering on screen for 5 seconds, then it fades. No voice, no head, no caption — just a ghost window.

**FIX:** In `recomputePanelVisibility`, gate the "visible" edge on whether the panel would have any renderable content (participants list non-empty OR caption would show). Or: when `showActiveAgents` is off, treat drone-only speech as `panelShouldBeVisible = false` unless Pulsar himself is speaking.

---

### [SEV high] `PopoverRootView.swift:57` — Default tab is History, not Team; first-run user never discovers drones exist

**WHY:** `selectedTab` defaults to `.history`. A new user opening the popover sees an empty history list. The Roster tab ("Team") — which explains what drones are and that the app does more than play audio — requires a manual tab switch the user has no reason to make. The tab bar icons are unlabelled (icon-only, line 184–209) and have no tooltip text that reveals content. The `.help()` modifier on each tab button (line 204) does show the tab name as a tooltip, but macOS tooltip delay means casual users never see it. No onboarding banner, no "you have 0 sessions — here's what Pulsar does" empty-state guidance in the history panel.

**FIX:** Set the default tab to `.roster` for first launch (check if history is empty); or add an empty-state in History with a "What is Pulsar?" hint that links to the Team tab.

---

### [SEV med] `say.sh:62–64` — `--mute` / `--unmute` flags print daemon JSON to stdout, breaking Claude Code's tool output

**WHY:** The `set-muted` action at line 126–127 calls `curl ... | python3 -m json.tool` — it prints the settings JSON response to stdout. When Claude Code runs `say.sh --mute`, this output lands in the Bash tool result that Claude Code sees. That's noise in the tool output and could confuse the model parsing the response, especially if the model is told to check exit status. All other actions (`speak`, `canon`) redirect to `/dev/null`. Mute/unmute is inconsistent.

**FIX:** Redirect the mute/unmute curl response to `/dev/null` (or make it conditional on a `--verbose` flag) so it matches the silent behaviour of the speak path.

---

### [SEV med] `SettingsView.swift:175–203` — Subtitles and Show Agents toggles disable silently when Floating Head is off, with no explanation of the dependency

**WHY:** Both toggles are `.disabled(viewModel.settings?.floatingHeadEnabled == false)` (lines 188, 203) — which is correct. But the visual affordance of a disabled toggle gives no reason: the user sees a greyed-out "Show subtitles" and doesn't know whether this is a permissions issue, a bug, or intentional. There is no conditional hint text that says "requires Floating Head to be enabled." Users who turn off the floating head for performance reasons will be puzzled why subtitles and agents are now un-toggleable.

**FIX:** When `floatingHeadEnabled` is false, change the toggle's description text to: "Requires floating head — enable above to use." One line, in the existing `.caption2.foregroundStyle(.tertiary)` Text.

---

### [SEV med] `FloatingHeadsView.swift:104` / `AppDelegate.swift:182–197` — Reduce Motion check is present but incomplete: the fade animation on panel hide doesn't respect it

**WHY:** `FloatingHeadsView` reads `@Environment(\.accessibilityReduceMotion)` (line 104) and Yuki's R1 noted the orbit bob doesn't honour it. Additionally, `AppDelegate.hidePanel` runs a 0.9-second animated alpha fade using `NSAnimationContext` (line 184–197) with no reduce-motion check. macOS's Reduce Motion setting should snap opacity to 0 rather than animate it. The 900ms fade plays for every reduce-motion user. This is also an issue for VoiceOver: the panel appearing/disappearing with animations and no accessibility label on the floating window means VoiceOver users get a window that pops in with no announcement.

**FIX:** In `AppDelegate.hidePanel`, check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` — if true, set `panel.alphaValue = 0` and call `panel.orderOut(nil)` synchronously, skipping the animation block.

---

### [SEV low] `stop-hook.sh:52–58` — Debounce reads `/queue` without checking drone presence; a drone-only active panel gets a canon ping stacked on top

**WHY:** The stop hook debounce checks if audio is currently playing or queued (line 52–58). It does NOT check whether the daemon considers the panel "busy" due to in-flight drones. If Pulsar just delegated (sub-agent registered, no speech yet), `playing=false` and `queued=0`, so the hook fires a canon "done" ping over a silent-but-occupied panel. The drone hasn't spoken yet; Pulsar immediately fires "Done. No hands, but consider it handled." — which is tonally wrong (nothing's done) and adds a queued item while drones are starting work.

**FIX:** Add a drone check to the debounce: `curl /queue` and check if `drones` is non-empty; if it is, skip the canon ping on that turn.

---

### [SEV low] `CaldwellHTTPServer.swift:284–285` / `say.sh:149–158` — Usage error printed to stderr in say.sh conflicts with silent-failure contract

**WHY:** `say.sh` prints usage to stderr and exits 1 when called with no text (lines 147–159). Claude Code's `session-start-voice.sh` directive tells the model "if say.sh exits non-zero, stay silent that turn." That's correct behaviour. But the stderr output — "Usage: say.sh …" — still surfaces in Claude Code's Bash tool stderr output, which the model may report to the user. A misconfigured call (say, the model omits the text and only passes `--agent`) produces visible error noise. `say.sh` has no way to suppress its own usage error.

**FIX:** This is low-risk as-is; the model follows the exit-code contract correctly. Consider adding a `--quiet` flag that suppresses the usage print on bad invocation.

---

## Single Highest-Priority Fix

**[SEV high] `showActiveAgents OFF` + drone speaking = ghost floating panel.**
This is the most jarring UX failure: the app opens a floating window over the user's screen showing nothing. It can happen whenever a sub-agent speaks and the user has "Show active agents" off — which is a user setting they chose deliberately. The fix is surgical: in `DashboardViewModel.recomputePanelVisibility` (or `panelShouldBeVisible`), gate visibility on whether any participant would actually render, not just on whether any audio event occurred.

---

## Question for another drone

For Sentinel or Nova: `NowPlayingView.swift` appears to be an orphaned view — I can see its implementation but can find no reference to it in `PopoverRootView.swift` or `HistoryPanelView.swift`. If it's not rendered anywhere, is it dead code? If it IS rendered somewhere not in these files, it has a UX issue: it shows `viewModel.playback.currentVoice` (Pulsar's voice label) but ignores `agentCategory`, so a drone speaking while this view is visible shows the wrong identity. Where does NowPlayingView actually render?

---

*— Atlas. What's the user actually trying to do here? They opened the popover because something happened (or didn't). Make that "something" legible.*
