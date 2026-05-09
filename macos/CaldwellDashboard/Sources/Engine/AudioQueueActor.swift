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

    // MARK: - Worker

    private func runWorker() async {
        while !queue.isEmpty {
            var entry = queue.removeFirst()

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
        }
        workerRunning = false
    }

    // MARK: - Playback

    private func playEntry(_ entry: AudioEntry) async {
        guard !entry.fetchFailed, let audioURL = entry.audioURL else {
            NSLog("[AudioQueue] Skipping \(entry.id) — fetch failed or no audio URL")
            await broadcaster.broadcast(event: "voice_active", json: jsonString(idlePayload(queued: queue.count)))
            recordHistory(entry: entry, duration: nil, failed: true)
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
        recordHistory(entry: entry, duration: duration, failed: false)
    }

    // MARK: - Helpers

    private func idlePayload(queued: Int) -> [String: Any] {
        ["id": NSNull(), "voice": NSNull(), "type": "idle",
         "text": NSNull(), "duration": NSNull(), "queued": queued]
    }

    private func recordHistory(entry: AudioEntry, duration: Double?, failed: Bool) {
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
