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
        default:
            break
        }
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
        let isActive = state.playing || state.queued > 0
        onPlaybackChanged?(isActive)
    }

    private func handleVoiceActiveEvent(_ data: Data) {
        guard let event = try? decoder.decode(VoiceActiveEvent.self, from: data) else { return }
        let wasActive = playback.isPlaying || playback.queuedCount > 0
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

        let isActive = playback.isPlaying || playback.queuedCount > 0
        if isActive != wasActive {
            onPlaybackChanged?(isActive)
        }
        updateQueuePolling(isActive: isActive)
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

    func saveSettings(muted: Bool? = nil, expletivesEnabled: Bool? = nil, canonEnabled: Bool? = nil, nativeVoice: String? = nil) async -> SaveResult {
        do {
            let response = try await api.saveSettings(muted: muted, expletivesEnabled: expletivesEnabled, canonEnabled: canonEnabled, nativeVoice: nativeVoice)
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
