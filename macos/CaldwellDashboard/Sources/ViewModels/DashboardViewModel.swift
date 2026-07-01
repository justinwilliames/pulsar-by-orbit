import AppKit
import Foundation
import SwiftUI

@Observable
@MainActor
final class DashboardViewModel {
    var playback = PlaybackState()
    var lipSync = LipSyncEngine()
    var portraitManager = PortraitManager()
    var connectionStatus: ConnectionStatus = .disconnected
    var voices: [Voice] = []
    var queueItems: [QueueItem] = []
    var historyEntries: [HistoryEntry] = []
    var settings: DaemonSettings?
    var cachedPhrases: [CachedPhrase] = []
    var cacheTotalBytes: Int = 0
    var cacheMaxBytes: Int = 0

    /// In-flight sub-agent drones (agentId → drone category). Driven by the
    /// "drones_in_flight" SSE event; rendered as orbiting drones around Pulsar.
    var inFlightDrones: [String: String] = [:]

    /// True while any sub-agent is running (SubagentStart → SubagentStop). A
    /// running sub-agent means the live team is at work; each such drone is a
    /// present participant (it orbits, and centres when it speaks).
    var hasInFlightDrones: Bool { !inFlightDrones.isEmpty }

    /// Whether PULSAR is a present participant — i.e. the MAIN session is
    /// actively working. Approximated (no new wiring) as: any drone in-flight (a
    /// running sub-agent implies the main session is working) OR Pulsar is
    /// actively speaking (`isPlaying`).
    ///
    /// CRITICAL: this keys on `isPlaying`, NOT `currentVoice != nil`.
    /// `currentVoice` persists through the post-line linger (it drives the
    /// centre-hold, cleared only in AppDelegate.hidePanel). If panel *visibility*
    /// also read `currentVoice`, the panel would stay "should be visible" for the
    /// whole linger, so `recomputePanelVisibility` would never see the true→false
    /// edge, never fire `onPlaybackChanged(false)`, and never schedule the 5s
    /// hide — leaving the head stuck on screen until the 45s max-visible ceiling.
    /// Keying on `isPlaying` lets visibility fall the instant audio ends (→ 5s
    /// hide timer), while `currentVoice` independently holds the centre + caption
    /// through that 5s + fade. The two mechanisms must stay decoupled.
    var pulsarIsPresent: Bool {
        hasInFlightDrones || playback.isPlaying
    }

    /// The panel is visible while ANY participant is present — Pulsar present OR
    /// any drone in-flight — plus the existing trailing linger. Activity-gated,
    /// not pure speech-gated: the orbit is the live team (Pulsar + running
    /// sub-agents), shown whenever anyone on it is active.
    var panelShouldBeVisible: Bool {
        pulsarIsPresent || hasInFlightDrones || playback.queuedCount > 0
    }

    /// Last value pushed to `onPlaybackChanged`, so we only fire on a real edge.
    private var lastPanelVisible = false

    /// ONE coherent snapshot of who is speaking right now, collapsing the four
    /// previously-independent signals (currentAgentCategory, inFlightDrones,
    /// amplitude, currentVoice) into a single source of truth. The floating
    /// views read ONLY this for the centre occupant, name card, and subtitle
    /// tint — so they can never desync or flicker against each other.
    ///
    /// nil = nothing is speaking. A `category` of nil inside the snapshot means
    /// Pulsar is the speaker (indigo); a real drone category means that drone.
    struct SpeakerSnapshot: Equatable {
        /// The drone category, or nil when Pulsar is speaking.
        let category: String?
        /// Resolved theme colour (drone colour, else Pulsar indigo).
        let color: Color
        /// Live mouth amplitude for the speaker.
        let amplitude: Float
        /// Pulsar's raw voice label (for the centre portrait's fallback monogram).
        let voiceLabel: String

        /// True when a real drone (not Pulsar) holds the line.
        var isDrone: Bool { category != nil }
    }

    /// The participant that HOLDS the big CENTRE slot — the one who spoke the
    /// current-or-lingering line. Keyed on `currentVoice`, which persists through
    /// the caption linger (it is cleared only on the idle SSE event, together
    /// with `currentText`), so the speaker STAYS big + centred for its whole
    /// line AND its entire fade-wait, then centre + caption fade away together.
    /// It NEVER flips to Pulsar (or any other participant) mid-linger, and never
    /// shrinks to the swarm while its caption is still up.
    ///
    /// `amplitude` naturally falls to 0 when audio ends (the envelope is spent),
    /// so the mouth stills while the portrait stays put. nil only when there is
    /// genuinely no current-or-lingering speaker → no centre, small swarm.
    var activeSpeaker: SpeakerSnapshot? {
        guard let voice = playback.currentVoice else { return nil }
        // Only a REAL drone category themes the speaker; nil = Pulsar (indigo).
        let cat = isDrone(playback.currentAgentCategory)
            ? playback.currentAgentCategory?.lowercased()
            : nil
        return SpeakerSnapshot(category: cat,
                               color: droneColor(for: cat),
                               amplitude: lipSync.amplitude,
                               voiceLabel: voice)
    }

    /// The drone category that themes the CAPTION (tint + name) — the SAME
    /// linger-surviving owner the centre uses, so centre + caption share one
    /// identity for the whole line + fade. nil = Pulsar (indigo) or no caption.
    var captionSpeakerCategory: String? {
        isDrone(playback.currentAgentCategory) ? playback.currentAgentCategory?.lowercased() : nil
    }

    /// O(1) lookup: is a given text string present in the phrase cache?
    var cachedTextIndex: [String: CachedPhrase] {
        Dictionary(cachedPhrases.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var onPlaybackChanged: ((Bool) -> Void)?

    private var sseClient: SSEClient?
    private let api = DaemonAPI()
    private let decoder = JSONDecoder()
    private var isQueueRefreshInFlight = false
    private var queueRefreshPending = false
    private var queuePollTimer: Timer?

    var uniqueChannels: [String] {
        let channels = Set(
            queueItems.compactMap(\.channel) + historyEntries.compactMap(\.channel)
        )
        return channels.sorted()
    }

    func voiceColor(for name: String) -> Color {
        voices.first(where: { $0.name == name })?.swiftUIColor ?? .blue
    }

    // MARK: - Connection

    func connect() {
        let port = DaemonAPI.defaultPort
        let url = URL(string: "http://127.0.0.1:\(port)/events")!
        sseClient = SSEClient(url: url, onEvent: { [weak self] event, data in
            guard let self else { return }
            Task { @MainActor in
                self.handleSSEEvent(event: event, data: data)
            }
        }, onStatusChange: { [weak self] status in
            guard let self else { return }
            Task { @MainActor in
                self.connectionStatus = status
                if status == .connected {
                    await self.loadVoices()
                }
            }
        })
        sseClient?.connect()
    }

    func disconnect() {
        sseClient?.disconnect()
    }

    // MARK: - SSE Event Handling

    private func handleSSEEvent(event: String, data: Data) {
        switch event {
        case "state":
            handleStateEvent(data)
        case "voice_active":
            handleVoiceActiveEvent(data)
        case "pause_state":
            handlePauseStateEvent(data)
        case "history_update":
            handleHistoryUpdateEvent(data)
        case "settings":
            handleSettingsEvent(data)
        case "drones_in_flight":
            handleDronesInFlightEvent(data)
        default:
            break
        }
    }

    /// A change to the set of in-flight sub-agent drones, pushed whenever a
    /// sub-agent starts or stops. Decodes {"drones": {agentId: category}}.
    /// Drives the panel directly: a silently-running sub-agent must show its
    /// drone even with nothing speaking (and the last despawn lets it hide).
    private func handleDronesInFlightEvent(_ data: Data) {
        guard let payload = try? decoder.decode(DronesInFlightEvent.self, from: data) else { return }
        inFlightDrones = payload.drones
        recomputePanelVisibility()
    }

    /// Fire `onPlaybackChanged` only when the should-be-visible edge flips, so
    /// the AppDelegate shows the panel (drones present OR speaking) and starts
    /// the hide linger when BOTH clear. Idempotent across redundant SSE events.
    private func recomputePanelVisibility() {
        let visible = panelShouldBeVisible
        guard visible != lastPanelVisible else { return }
        lastPanelVisible = visible
        onPlaybackChanged?(visible)
    }

    /// A settings change pushed from the daemon (e.g. mute toggled via the API,
    /// the Stop hook, or say.sh). Refreshes `settings` so `isMuted` — and the
    /// menubar glyph that reads it — update immediately, not just on the next
    /// popover toggle or reconnect.
    private func handleSettingsEvent(_ data: Data) {
        guard let updated = try? decoder.decode(DaemonSettings.self, from: data) else { return }
        settings = updated
    }

    private func handleStateEvent(_ data: Data) {
        guard let state = try? decoder.decode(QueueStatusResponse.self, from: data) else { return }
        applyQueueStatus(state)
        recomputePanelVisibility()
    }

    private func handleVoiceActiveEvent(_ data: Data) {
        guard let event = try? decoder.decode(VoiceActiveEvent.self, from: data) else { return }
        let previousQueuedCount = playback.queuedCount
        let previousCurrentId = playback.currentId
        playback.updateFromVoiceActive(event)

        if playback.isPlaying, let voice = event.voice {
            lipSync.start(
                voiceName: voice,
                envelope: event.envelope ?? [],
                chunkMs: event.chunkMs ?? 50
            )
        } else {
            lipSync.stop()
        }

        // Update queue count
        playback.queuedCount = event.queued ?? 0

        let shouldRefreshQueue = previousQueuedCount != playback.queuedCount ||
            previousCurrentId != playback.currentId ||
            (playback.queuedCount > 0 && queueItems.isEmpty) ||
            (event.type == "idle" && !queueItems.isEmpty)
        if shouldRefreshQueue {
            requestQueueRefresh()
        }

        recomputePanelVisibility()
        // Queue polling tracks audio activity specifically (not drone presence).
        let audioActive = playback.isPlaying || playback.queuedCount > 0
        updateQueuePolling(isActive: audioActive)
    }

    private func updateQueuePolling(isActive: Bool) {
        if isActive && queuePollTimer == nil {
            queuePollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestQueueRefresh()
                }
            }
        } else if !isActive {
            queuePollTimer?.invalidate()
            queuePollTimer = nil
        }
    }

    private func applyQueueStatus(_ state: QueueStatusResponse) {
        queueItems = state.items
        playback.queuedCount = state.queued
        playback.globalPaused = state.paused
        playback.channelPaused = state.channelPaused
        if let history = state.recentHistory {
            historyEntries = history
        }
    }

    private func requestQueueRefresh() {
        if isQueueRefreshInFlight {
            queueRefreshPending = true
            return
        }

        isQueueRefreshInFlight = true
        Task { [weak self] in
            await self?.refreshQueueStatus()
        }
    }

    private func refreshQueueStatus() async {
        defer {
            isQueueRefreshInFlight = false
            if queueRefreshPending {
                queueRefreshPending = false
                requestQueueRefresh()
            }
        }

        guard let state = try? await api.fetchQueueStatus() else { return }
        applyQueueStatus(state)
    }

    private func handlePauseStateEvent(_ data: Data) {
        guard let event = try? decoder.decode(PauseStateEvent.self, from: data) else { return }
        playback.updateFromPauseState(event)

        if event.globalPaused {
            lipSync.pause()
        } else {
            lipSync.resume()
        }
    }

    private func handleHistoryUpdateEvent(_ data: Data) {
        guard let entry = try? decoder.decode(HistoryEntry.self, from: data) else { return }
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > 200 {
            historyEntries = Array(historyEntries.prefix(200))
        }
        // Refresh cached index so the new entry's cached-badge shows immediately.
        Task { await loadCachedPhrases() }
    }

    // MARK: - Actions

    func pause() async {
        try? await api.pause()
    }

    func resume() async {
        try? await api.resume()
    }

    func skip() async {
        try? await api.skip()
    }

    func seek(offset: Double) async {
        try? await api.seek(offset: offset)
    }

    func replay(id: String) async {
        try? await api.replay(id: id)
    }

    func clearQueue() async {
        try? await api.clearQueue()
    }

    func pauseChannel(_ channel: String) async {
        try? await api.pause(channel: channel)
    }

    func resumeChannel(_ channel: String) async {
        try? await api.resume(channel: channel)
    }

    func loadMoreHistory() async {
        let offset = historyEntries.count
        guard let response = try? await api.fetchHistory(limit: 50, offset: offset) else { return }
        historyEntries.append(contentsOf: response.entries)
    }

    // MARK: - Phrase Cache

    func loadCachedPhrases() async {
        guard let response = try? await api.fetchCachedPhrases(sort: .recent) else { return }
        cachedPhrases = response.phrases
        cacheTotalBytes = response.totalSizeBytes
        cacheMaxBytes = response.maxBytes
    }

    func playCachedPhrase(key: String) async {
        try? await api.playCachedPhrase(key: key)
        await loadCachedPhrases()
    }

    private func loadVoices() async {
        guard voices.isEmpty else { return }
        if let fetched = try? await api.fetchVoices() {
            voices = fetched
        }
    }

    // MARK: - Settings

    enum SaveResult {
        case success
        case failure(String)
    }

    func loadSettings() async {
        // Keep the last-known settings if a fetch momentarily fails, rather
        // than blanking the UI — a transient daemon hiccup shouldn't wipe state.
        if let fresh = try? await api.fetchSettings() {
            settings = fresh
        }
    }

    func saveSettings(muted: Bool? = nil, expletivesEnabled: Bool? = nil, canonEnabled: Bool? = nil, floatingHeadEnabled: Bool? = nil, subtitlesEnabled: Bool? = nil, nativeVoice: String? = nil) async -> SaveResult {
        do {
            let response = try await api.saveSettings(muted: muted, expletivesEnabled: expletivesEnabled, canonEnabled: canonEnabled, floatingHeadEnabled: floatingHeadEnabled, subtitlesEnabled: subtitlesEnabled, nativeVoice: nativeVoice)
            if let error = response.error {
                return .failure(error)
            }
            await loadSettings()
            return .success
        } catch {
            return .failure("Network error: \(error.localizedDescription)")
        }
    }

    /// Voice register: false = Polite (clean), true = Potty Mouth (expletives).
    func setExpletivesEnabled(_ on: Bool) async {
        _ = await saveSettings(expletivesEnabled: on)
    }

    var isExpletivesEnabled: Bool {
        settings?.expletivesEnabled ?? false
    }

    /// Message style: cached pings on (frequent, notification-style) vs off
    /// (bespoke-only — richer, fewer).
    func setCanonEnabled(_ on: Bool) async {
        _ = await saveSettings(canonEnabled: on)
    }

    /// Floating-head visibility: on = show the animated Pulsar head when it
    /// speaks; off = voice only, no floating window.
    func setFloatingHeadEnabled(_ on: Bool) async {
        _ = await saveSettings(floatingHeadEnabled: on)
    }

    var isFloatingHeadEnabled: Bool {
        settings?.floatingHeadEnabled ?? true
    }

    /// Read-along caption bubble: on = show the spoken line below the head;
    /// off = head only. Gated by the floating head being visible.
    func setSubtitlesEnabled(_ on: Bool) async {
        _ = await saveSettings(subtitlesEnabled: on)
    }

    var isSubtitlesEnabled: Bool {
        settings?.subtitlesEnabled ?? true
    }

    /// Free-mode local voice choice. Empty resets to auto (Daniel Enhanced else
    /// Daniel). Only installed voices are accepted by the daemon.
    func setNativeVoice(_ name: String) async {
        _ = await saveSettings(nativeVoice: name)
    }

    /// Quick mute toggle for the popover header + menu-bar quick action.
    /// Optimistically flips local state, then syncs to the daemon.
    @discardableResult
    func toggleMute() async -> Bool {
        let current = settings?.muted ?? false
        let next = !current
        _ = await saveSettings(muted: next)
        return next
    }

    var isMuted: Bool {
        settings?.muted ?? false
    }
}
