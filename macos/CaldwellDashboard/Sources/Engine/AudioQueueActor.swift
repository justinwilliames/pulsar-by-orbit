import Foundation

// MARK: - SSE Broadcaster

/// Phase 4 will inject a real SSE broadcaster; Phase 2 logs only.
/// The payload is pre-serialised to a JSON string so the protocol is Sendable-clean.
protocol SSEBroadcasterProtocol: Sendable {
    func broadcast(event: String, json: String) async
}

struct NoOpBroadcaster: SSEBroadcasterProtocol {
    func broadcast(event: String, json: String) async {
        NSLog("[SSE-stub] \(event): \(json.prefix(80))")
    }
}

// MARK: - Payload helpers (nonisolated — no actor state captured)

private func jsonString(_ dict: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

// MARK: - Data types

struct AudioEntry: Sendable {
    let id: String
    let text: String
    let voiceId: String
    let voiceLabel: String
    let createdAt: Date
    let channel: String?
    let priority: Bool
    let fullText: String
    let isReplay: Bool
    var audioURL: URL?
    var fetchFailed: Bool = false
}

struct HistoryItem: Sendable {
    let id: String
    let voice: String
    let text: String
    let channel: String?
    let timestamp: Date
    let duration: Double?
    let failed: Bool
}

struct QueueStatusSnapshot: Encodable, Sendable {
    let playing: Bool
    let queued: Int
    let total: Int
    let items: [QueueStatusSnapshotItem]
    let paused: Bool
    let channelPaused: [String]
    let recentHistory: [QueueStatusHistorySnapshot]

    enum CodingKeys: String, CodingKey {
        case playing
        case queued
        case total
        case items
        case paused
        case channelPaused = "channel_paused"
        case recentHistory = "recent_history"
    }
}

struct QueueStatusSnapshotItem: Encodable, Sendable {
    let position: Int
    let status: String
    let id: String
    let voice: String
    let text: String
    let channel: String?
    let priority: Bool
}

struct QueueStatusHistorySnapshot: Encodable, Sendable {
    let id: String
    let voice: String
    let text: String
    let channel: String?
    let timestamp: Double
    let duration: Double?
    let type: String
    let failed: Bool
}

// MARK: - AudioQueueActor

/// Serial audio playback queue. One utterance plays at a time via `afplay`.
///
/// Entries with a cache-hit arrive with `audioURL` already set; cache-miss
/// entries arrive with `audioURL = nil`. The HTTP handler races a background
/// fetch and calls `markReady` / `markFailed` when it resolves, waking the
/// worker via a per-entry `CheckedContinuation`.
actor AudioQueueActor {

    var broadcaster: any SSEBroadcasterProtocol = NoOpBroadcaster()

    private(set) var history: [HistoryItem] = []
    private let maxHistory = 200

    private var queue: [AudioEntry] = []
    private var workerRunning = false
    private var currentProcess: Process?
    private var currentEntry: AudioEntry?

    // Keyed by entry ID. Populated for nil-audioURL entries on enqueue;
    // resumed by markReady/markFailed.
    private var readyContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    // Resolved URLs for entries that were already popped from `queue`
    // when markReady fires. Worker reads here after continuation resumes.
    private var resolvedURLs: [String: URL] = [:]

    // MARK: - Public API

    /// Add an entry to the queue. Returns queue depth after insertion.
    func enqueue(_ entry: AudioEntry) -> Int {
        queue.append(entry)
        if !workerRunning {
            workerRunning = true
            Task { await runWorker() }
        }
        return queue.count
    }

    /// Called by the background TTS fetch task when audio is ready.
    func markReady(id: String, url: URL) {
        resolvedURLs[id] = url
        readyContinuations[id]?.resume()
        readyContinuations.removeValue(forKey: id)
    }

    /// Called by the background TTS fetch task on failure.
    func markFailed(id: String) {
        readyContinuations[id]?.resume()
        readyContinuations.removeValue(forKey: id)
    }

    func stopCurrent() {
        currentProcess?.terminate()
    }

    func setBroadcaster(_ broadcaster: any SSEBroadcasterProtocol) {
        self.broadcaster = broadcaster
    }

    func historyItems(limit: Int, offset: Int = 0, channel: String? = nil) -> [HistoryItem] {
        let filtered = channel.map { name in
            history.filter { $0.channel == name }
        } ?? history
        let reversed = Array(filtered.reversed())
        guard offset < reversed.count else { return [] }
        let end = min(offset + limit, reversed.count)
        return Array(reversed[offset..<end])
    }

    func statusSnapshot(limit: Int = 20, channel: String? = nil) -> QueueStatusSnapshot {
        var items: [QueueStatusSnapshotItem] = []

        if let currentEntry, channel == nil || currentEntry.channel == channel {
            items.append(QueueStatusSnapshotItem(
                position: 0,
                status: "playing",
                id: currentEntry.id,
                voice: currentEntry.voiceLabel,
                text: currentEntry.text,
                channel: currentEntry.channel,
                priority: currentEntry.priority
            ))
        }

        for (index, entry) in queue.enumerated() {
            if channel != nil, entry.channel != channel {
                continue
            }
            let isReady = entry.audioURL != nil || resolvedURLs[entry.id] != nil
            items.append(QueueStatusSnapshotItem(
                position: index + 1,
                status: isReady ? "queued" : "pending",
                id: entry.id,
                voice: entry.voiceLabel,
                text: entry.text,
                channel: entry.channel,
                priority: entry.priority
            ))
        }

        let recentHistory = historyItems(limit: limit, channel: channel).map {
            QueueStatusHistorySnapshot(
                id: $0.id,
                voice: $0.voice,
                text: $0.text,
                channel: $0.channel,
                timestamp: $0.timestamp.timeIntervalSince1970,
                duration: $0.duration,
                type: "speak",
                failed: $0.failed
            )
        }

        return QueueStatusSnapshot(
            playing: currentEntry != nil,
            queued: queue.count,
            total: items.count,
            items: items,
            paused: false,
            channelPaused: [],
            recentHistory: recentHistory
        )
    }

    // MARK: - Worker

    private func runWorker() async {
        while !queue.isEmpty {
            var entry = queue.removeFirst()
            currentEntry = entry

            // Wait for the audio URL if not yet available.
            if entry.audioURL == nil && !entry.fetchFailed {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    readyContinuations[entry.id] = cont
                }
            }

            // Pick up URL from resolvedURLs (set by markReady after pop).
            if entry.audioURL == nil {
                entry.audioURL = resolvedURLs.removeValue(forKey: entry.id)
            }

            await playEntry(entry)
            currentEntry = nil
        }
        currentEntry = nil
        workerRunning = false
    }

    // MARK: - Playback

    private func playEntry(_ entry: AudioEntry) async {
        guard !entry.fetchFailed, let audioURL = entry.audioURL else {
            NSLog("[AudioQueue] Skipping \(entry.id) — fetch failed or no audio URL")
            await broadcaster.broadcast(event: "voice_active", json: jsonString(idlePayload(queued: queue.count)))
            let historyItem = recordHistory(entry: entry, duration: nil, failed: true)
            await broadcaster.broadcast(
                event: "history_update",
                json: jsonString(historyPayload(for: historyItem, type: entry.isReplay ? "replay" : "speak"))
            )
            return
        }

        let duration = audioDuration(url: audioURL)
        let startDict: [String: Any] = [
            "id": entry.id,
            "voice": entry.voiceLabel,
            "type": entry.isReplay ? "replay" : "speak",
            "text": String(entry.text.prefix(100)),
            "duration": duration as Any,
            "queued": queue.count,
            "channel": entry.channel as Any,
            "priority": entry.priority,
        ]
        await broadcaster.broadcast(event: "voice_active", json: jsonString(startDict))

        NSLog("[AudioQueue] ▶ \(entry.id) '\(entry.text.prefix(60))'")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [audioURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        currentProcess = process

        do {
            try process.run()
            // Wait off-actor so we don't block other actor calls during playback.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Task.detached {
                    process.waitUntilExit()
                    cont.resume()
                }
            }
        } catch {
            NSLog("[AudioQueue] afplay launch failed: \(error)")
        }

        currentProcess = nil

        // Clean up temp files only — leave phrase-cache files intact.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).standardized.path
        if audioURL.standardized.path.hasPrefix(tmpDir) {
            try? FileManager.default.removeItem(at: audioURL)
        }

        await broadcaster.broadcast(event: "voice_active", json: jsonString(idlePayload(queued: queue.count)))
        let historyItem = recordHistory(entry: entry, duration: duration, failed: false)
        await broadcaster.broadcast(
            event: "history_update",
            json: jsonString(historyPayload(for: historyItem, type: entry.isReplay ? "replay" : "speak"))
        )
    }

    // MARK: - Helpers

    private func idlePayload(queued: Int) -> [String: Any] {
        ["id": NSNull(), "voice": NSNull(), "type": "idle",
         "text": NSNull(), "duration": NSNull(), "queued": queued]
    }

    private func historyPayload(for item: HistoryItem, type: String) -> [String: Any] {
        [
            "id": item.id,
            "voice": item.voice,
            "text": item.text,
            "channel": item.channel as Any,
            "timestamp": item.timestamp.timeIntervalSince1970,
            "duration": item.duration as Any,
            "type": type,
            "failed": item.failed,
        ]
    }

    @discardableResult
    private func recordHistory(entry: AudioEntry, duration: Double?, failed: Bool) -> HistoryItem {
        let item = HistoryItem(
            id: entry.id, voice: entry.voiceLabel,
            text: entry.fullText.isEmpty ? entry.text : entry.fullText,
            channel: entry.channel, timestamp: entry.createdAt,
            duration: duration, failed: failed
        )
        history.append(item)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
        return item
    }

    /// Synchronously reads audio duration via `afinfo`. Runs on the calling
    /// context — call from a non-actor thread or wrap in Task.detached if needed.
    private func audioDuration(url: URL) -> Double? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        proc.arguments = [url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        // afinfo prints e.g. "estimated duration: 1.234 sec"
        for line in output.components(separatedBy: "\n") {
            let lower = line.lowercased()
            if lower.contains("duration") {
                let tokens = line.components(separatedBy: " ")
                for token in tokens {
                    if let d = Double(token), d > 0 { return d }
                }
            }
        }
        return nil
    }
}
