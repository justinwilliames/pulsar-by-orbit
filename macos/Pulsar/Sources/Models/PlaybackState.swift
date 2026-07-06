import Foundation

@Observable
@MainActor
final class PlaybackState {
    var isPlaying = false
    var currentVoice: String?
    var currentText: String?
    var currentId: String?
    var currentType: String = "idle"
    var duration: Double?
    var totalDuration: Double?
    var offset: Double = 0
    var elapsed: Double = 0
    var envelope: [Float] = []
    var chunkMs: Int = 50
    var queuedCount: Int = 0
    var channel: String?
    /// Drone category attributed to the currently-speaking line (e.g. "voyager").
    /// nil = the main Pulsar head is speaking.
    var currentAgentCategory: String?

    var globalPaused = false
    var channelPaused: [String] = []

    private var playbackStartedAt: Date?
    private var elapsedTimer: Timer?

    func updateFromVoiceActive(_ data: VoiceActiveEvent) {
        stopTimer()
        if data.type == "idle" {
            // Audio finished. Keep currentVoice + currentText AND
            // currentAgentCategory set so the floating panel keeps rendering the
            // SPEAKER — the exact participant who spoke — big + centred with its
            // own caption through the linger/fade. Clearing the category here was
            // the "flips back to Pulsar after a drone speaks" bug: currentVoice
            // lingered but the drone identity was wiped, so the centre fell back
            // to Pulsar (nil category = Pulsar). The category is replaced when the
            // NEXT line arrives (else branch) or cleared when the panel hides.
            isPlaying = false
            currentId = nil
            currentType = "idle"
            duration = nil
            totalDuration = nil
            offset = 0
            elapsed = 0
            envelope = []
        } else {
            isPlaying = true
            currentVoice = data.voice
            currentText = data.text
            currentId = data.id
            currentType = data.type ?? "speak"
            duration = data.duration
            totalDuration = data.totalDuration
            offset = data.offset ?? 0
            elapsed = data.offset ?? 0
            envelope = data.envelope ?? []
            chunkMs = data.chunkMs ?? 50
            channel = data.channel
            currentAgentCategory = data.agent
            startTimer()
        }
        queuedCount = data.queued ?? 0
    }

    private func startTimer() {
        playbackStartedAt = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickElapsed()
            }
        }
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        playbackStartedAt = nil
    }

    private func tickElapsed() {
        guard let startedAt = playbackStartedAt, !globalPaused else { return }
        let total = totalDuration ?? duration ?? 0
        elapsed = min(offset + Date().timeIntervalSince(startedAt), total)
    }

    func updateFromPauseState(_ data: PauseStateEvent) {
        globalPaused = data.globalPaused
        channelPaused = data.channelPaused
    }
}

struct VoiceActiveEvent: Codable {
    let id: String?
    let voice: String?
    let type: String?
    let text: String?
    let duration: Double?
    let totalDuration: Double?
    let offset: Double?
    let segments: [DialogueSegment]?
    let envelope: [Float]?
    let chunkMs: Int?
    let queued: Int?
    let channel: String?
    let priority: Bool?
    let agent: String?

    enum CodingKeys: String, CodingKey {
        case id, voice, type, text, duration
        case totalDuration = "total_duration"
        case offset, segments, envelope
        case chunkMs = "chunk_ms"
        case queued, channel, priority, agent
    }
}

struct DialogueSegment: Codable {
    let voice: String
    let text: String
    let chars: Int
    let start: Double?
    let end: Double?
}

/// The set of currently in-flight sub-agent drones, pushed over SSE whenever a
/// sub-agent starts or stops. Maps agentId → drone category.
struct DronesInFlightEvent: Codable {
    let drones: [String: String]
}

// MARK: - Session grouping (Missions board)

/// The session-grouping payload — the `sessions` SSE event and the `/sessions`
/// GET share this exact snake_case shape. Each session nests its drones.
struct SessionsEnvelope: Codable, Sendable {
    let sessions: [SessionDTO]
}

struct SessionDTO: Codable, Sendable {
    let session_id: String
    let name: String
    let label: String
    let phase: String
    let last_seen: Int
    // Optional so a daemon that predates the Session Signature fields still
    // decodes (belt-and-braces in both directions); the mapper defaults them.
    let branch: String?
    let repo: String?
    let last_action: String?
    let user_named: Bool?
    /// The REAL Claude Desktop sidebar title (optional so an older daemon that
    /// omits it still decodes); the mapper defaults it to "".
    let sidebar_title: String?
    /// LIVE heartbeat layer (PreToolUse). Optional so an older daemon that omits
    /// them still decodes; the mapper defaults to false/"".
    let active_now: Bool?
    let current_action: String?
    let active_category: String?
    /// SERVER-RESOLVED presentation truth (2026-07-06 review, R4 item 3): the
    /// one `title`, the honest `status` ("active"|"working"|"waiting"),
    /// idle-fallback `stale` provenance, the window's real gate+sort key
    /// `last_user_message`, and `is_mission` (this session needs the user).
    /// All optional so an older daemon still decodes; the mapper falls back to
    /// the legacy client-side derivations when absent.
    let title: String?
    let status: String?
    let stale: Bool?
    let last_user_message: Int?
    let is_mission: Bool?
    let drones: [SessionDroneDTO]
}

struct SessionDroneDTO: Codable, Sendable {
    let agent_id: String
    let category: String
}

struct PauseStateEvent: Codable {
    let globalPaused: Bool
    let channelPaused: [String]

    enum CodingKeys: String, CodingKey {
        case globalPaused = "global_paused"
        case channelPaused = "channel_paused"
    }
}

struct QueueStatusResponse: Codable {
    let playing: Bool
    let queued: Int
    let total: Int
    let items: [QueueItem]
    let paused: Bool
    let channelPaused: [String]
    let recentHistory: [HistoryEntry]?

    enum CodingKeys: String, CodingKey {
        case playing, queued, total, items, paused
        case channelPaused = "channel_paused"
        case recentHistory = "recent_history"
    }
}

struct HistoryResponse: Codable {
    let entries: [HistoryEntry]
    let total: Int

    enum CodingKeys: String, CodingKey {
        case entries
        case total
    }

    init(from decoder: Decoder) throws {
        if let entries = try? decoder.singleValueContainer().decode([HistoryEntry].self) {
            self.entries = entries
            self.total = entries.count
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.entries = try container.decode([HistoryEntry].self, forKey: .entries)
        self.total = try container.decodeIfPresent(Int.self, forKey: .total) ?? entries.count
    }
}
