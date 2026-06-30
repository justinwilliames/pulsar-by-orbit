import Foundation
import AVFoundation

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

/// Read PCM samples and compute a per-chunk RMS envelope, normalised to the
/// 95th percentile. Mirrors the daemon's old Python implementation so the
/// LipSyncEngine receives the same shape of data it always did. Returns an
/// empty array on any failure — caller's guards handle that.
func extractEnvelope(url: URL, chunkMs: Int) -> [Float] {
    guard let file = try? AVAudioFile(forReading: url) else { return [] }
    let processingFormat = file.processingFormat
    let sampleRate = processingFormat.sampleRate
    guard sampleRate > 0 else { return [] }

    let samplesPerChunk = AVAudioFrameCount(sampleRate * Double(chunkMs) / 1000.0)
    guard samplesPerChunk > 0 else { return [] }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    do {
        try file.read(into: buffer)
    } catch {
        return []
    }

    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(processingFormat.channelCount)
    guard frameLength > 0, channelCount > 0,
          let channelData = buffer.floatChannelData else { return [] }

    var envelope: [Float] = []
    envelope.reserveCapacity(frameLength / Int(samplesPerChunk) + 1)

    var i = 0
    while i < frameLength {
        let end = min(i + Int(samplesPerChunk), frameLength)
        var sumSq: Float = 0
        var n: Int = 0
        for c in 0..<channelCount {
            let ptr = channelData[c]
            for j in i..<end {
                let v = ptr[j]
                sumSq += v * v
                n += 1
            }
        }
        if n > 0 {
            envelope.append((sumSq / Float(n)).squareRoot())
        }
        i += Int(samplesPerChunk)
    }

    guard !envelope.isEmpty else { return [] }
    let sorted = envelope.sorted()
    let p95Index = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
    let p95 = max(sorted[p95Index], 0.001)
    return envelope.map { min($0 / p95, 1.0) }
}

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
    /// Which engine produced the audio. Always "native" now — ElevenLabs removed.
    var engine: String = "native"
    /// Drone category this line is attributed to (e.g. "voyager"). nil/"pulsar"
    /// = the main Pulsar head speaks; a drone category makes that drone the
    /// active speaker for the line's duration.
    var agentCategory: String?
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

    // MARK: - In-flight sub-agent drones

    /// Currently in-flight sub-agents, keyed by agentId → drone category. The
    /// UI renders one orbiting drone per entry; populated by /subagent/start,
    /// cleared by /subagent/stop.
    private var inFlight: [String: String] = [:]

    /// Record a newly-spawned sub-agent as in-flight under its drone category.
    func addInFlightDrone(id: String, category: String) {
        inFlight[id] = category
    }

    /// Remove a finished sub-agent from the in-flight set.
    func removeInFlightDrone(id: String) {
        inFlight.removeValue(forKey: id)
    }

    /// Snapshot of the current in-flight drones (agentId → category).
    func inFlightDronesSnapshot() -> [String: String] {
        inFlight
    }

    // MARK: - Public API

    /// Maximum number of entries allowed to wait behind the currently-playing
    /// one. Cap of 1 means: one playing + at most one waiting. Anything beyond
    /// that gets dropped at enqueue. Sir's call — if it doesn't play, it
    /// doesn't play.
    static let maxWaitingDepth = 1

    /// Add an entry to the queue. Returns queue depth after insertion, or
    /// nil if the queue was full and the entry was dropped.
    func enqueue(_ entry: AudioEntry) -> Int? {
        if queue.count >= Self.maxWaitingDepth {
            NSLog("[AudioQueue] ✋ dropped '\(entry.text.prefix(60))' — busy (waiting=\(queue.count))")
            return nil
        }
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

    /// Maximum time the worker will wait for a background fetch before giving
    /// up on an entry and moving on. Without this, a hung URLSession call
    /// wedges the entire queue — and because `/speak` spawns a fetch eagerly,
    /// every subsequent enqueue burns ElevenLabs quota for audio nobody hears.
    static let fetchWaitTimeoutSeconds: UInt64 = 30

    private func runWorker() async {
        while !queue.isEmpty {
            var entry = queue.removeFirst()
            currentEntry = entry

            // Resolution may have raced ahead of us — check the resolved
            // table before setting up a continuation we'd be stuck on.
            if entry.audioURL == nil, !entry.fetchFailed,
               let pre = resolvedURLs.removeValue(forKey: entry.id) {
                entry.audioURL = pre
            }

            // Wait for the audio URL if still not available.
            if entry.audioURL == nil && !entry.fetchFailed {
                let entryId = entry.id
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    readyContinuations[entryId] = cont
                    // Watchdog: if no markReady/markFailed arrives in
                    // `fetchWaitTimeoutSeconds`, resume the continuation
                    // ourselves and skip this entry.
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: Self.fetchWaitTimeoutSeconds * 1_000_000_000)
                        await self?.timeoutEntry(id: entryId)
                    }
                }
                entry.audioURL = resolvedURLs.removeValue(forKey: entry.id)
                if entry.audioURL == nil {
                    entry.fetchFailed = true
                }
            }

            await playEntry(entry)
            currentEntry = nil
        }
        currentEntry = nil
        workerRunning = false
    }

    /// Watchdog: if a fetch never reports back, free the worker.
    /// Idempotent — safe if markReady/markFailed already cleared the entry.
    func timeoutEntry(id: String) {
        guard let cont = readyContinuations.removeValue(forKey: id) else { return }
        NSLog("[AudioQueue] ⏱ fetch timeout for \(id) after \(Self.fetchWaitTimeoutSeconds)s — skipping")
        cont.resume()
    }

    // MARK: - Playback

    /// Zero-cost voice fallback: speak `text` via the macOS `say` command in a
    /// British voice when ElevenLabs synthesis is unavailable, so Caldwell never
    /// goes silent on a failed fetch. Voice overridable via the
    /// CALDWELL_FALLBACK_VOICE env var (default "Daniel"). Best-effort — launch
    /// errors are logged and swallowed. Reuses `currentProcess` so --skip can
    /// interrupt it like any premium line.
    private func speakNative(_ text: String) async {
        // Honour the global mute exactly like the premium voice. Mute is already
        // enforced upstream at /speak (muted requests never enqueue), so muted
        // lines normally never reach here — but this guard also catches the
        // race where the user mutes mid-flight, after a line was queued. A mute
        // silences Daniel, not just ElevenLabs.
        guard !CaldwellConfig.shared.isMuted else {
            NSLog("[AudioQueue] native say fallback suppressed — muted")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let voice = NativeVoiceClient.bestVoice()
        NSLog("[AudioQueue] native say last-ditch voice=\(voice)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-r", String(NativeVoiceClient.defaultRate), trimmed]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        currentProcess = process
        do {
            try process.run()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Task.detached {
                    process.waitUntilExit()
                    cont.resume()
                }
            }
        } catch {
            NSLog("[AudioQueue] native say fallback failed: \(error)")
        }
        currentProcess = nil
    }

    private func playEntry(_ entry: AudioEntry) async {
        guard !entry.fetchFailed, let audioURL = entry.audioURL else {
            // ElevenLabs synthesis was unavailable (missing/invalid key,
            // exhausted quota, or invalid audio). Rather than go mute, speak the
            // line through the macOS `say` command in a British voice — free, no
            // ElevenLabs spend. Mute is enforced upstream at /speak (muted
            // requests never enqueue), so reaching here means the user wants to
            // hear Caldwell and only the premium voice failed.
            NSLog("[AudioQueue] fetch failed for \(entry.id) — native say fallback")
            await speakNative(entry.text)
            await broadcaster.broadcast(event: "voice_active", json: jsonString(idlePayload(queued: queue.count)))
            let historyItem = recordHistory(entry: entry, duration: nil, failed: true)
            await broadcaster.broadcast(
                event: "history_update",
                json: jsonString(historyPayload(for: historyItem, type: entry.isReplay ? "replay" : "speak"))
            )
            return
        }

        let fileDuration = audioDuration(url: audioURL)
        let chunkMs = 50
        let envelope = await Task.detached { extractEnvelope(url: audioURL, chunkMs: chunkMs) }.value
        // Compute where speech actually ends so we can kill afplay before it
        // plays through ElevenLabs' trailing silence. Falls back to fileDuration
        // when the envelope is unusable.
        let effectiveDuration = effectiveSpeechEnd(envelope: envelope, chunkMs: chunkMs, fallback: fileDuration)
        let startDict: [String: Any] = [
            "id": entry.id,
            "voice": entry.voiceLabel,
            "type": entry.isReplay ? "replay" : "speak",
            // FULL line for the read-along caption. `entry.text` is only a 100-char
            // preview (for the menu bar / history); the caption needs the whole line,
            // otherwise it's silently cut off at ~3 rows regardless of any UI fix.
            "text": entry.fullText.isEmpty ? entry.text : entry.fullText,
            "duration": effectiveDuration as Any,
            "envelope": envelope,
            "chunk_ms": chunkMs,
            "queued": queue.count,
            "channel": entry.channel as Any,
            "priority": entry.priority,
            "agent": entry.agentCategory as Any,
        ]
        await broadcaster.broadcast(event: "voice_active", json: jsonString(startDict))

        NSLog("[AudioQueue] ▶ \(entry.id) '\(entry.text.prefix(60))' eff=\(effectiveDuration ?? -1)s file=\(fileDuration ?? -1)s")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [audioURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        currentProcess = process

        do {
            try process.run()
            // Wait off-actor so we don't block other actor calls during playback.
            // Race two tasks: natural exit, or the effective-end deadline.
            // First one to finish wins; the other gets cancelled.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let exitTask = Task.detached {
                    process.waitUntilExit()
                }
                let killTask: Task<Void, Never>?
                if let cutoff = effectiveDuration, cutoff > 0,
                   fileDuration == nil || cutoff < (fileDuration ?? 0) - 0.05 {
                    killTask = Task.detached {
                        try? await Task.sleep(nanoseconds: UInt64(cutoff * 1_000_000_000))
                        if process.isRunning { process.terminate() }
                    }
                } else {
                    killTask = nil
                }
                Task.detached {
                    await exitTask.value
                    killTask?.cancel()
                    cont.resume()
                }
            }
        } catch {
            NSLog("[AudioQueue] afplay launch failed: \(error)")
        }

        currentProcess = nil

        // Retain a per-history-item copy keyed by entry id BEFORE temp cleanup,
        // so /history/replay works for EVERY played line — not just the
        // cache-eligible canon that lands in the phrase cache. Reaching here
        // means playback succeeded (the failed branch returned above).
        retainHistoryAudio(id: entry.id, sourceURL: audioURL)

        // Clean up temp files only — leave phrase-cache files intact.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).standardized.path
        if audioURL.standardized.path.hasPrefix(tmpDir) {
            try? FileManager.default.removeItem(at: audioURL)
        }

        await broadcaster.broadcast(event: "voice_active", json: jsonString(idlePayload(queued: queue.count)))
        let historyItem = recordHistory(entry: entry, duration: effectiveDuration, failed: false)
        await broadcaster.broadcast(
            event: "history_update",
            json: jsonString(historyPayload(for: historyItem, type: entry.isReplay ? "replay" : "speak"))
        )
    }

    /// Walk back from the end of the envelope to find the last chunk loud
    /// enough to be considered speech, then add a small tail so words don't
    /// get clipped. Returns nil only if envelope is empty.
    private func effectiveSpeechEnd(envelope: [Float], chunkMs: Int, fallback: Double?) -> Double? {
        guard !envelope.isEmpty else { return fallback }
        // Bias hard toward NOT clipping: a touch of trailing silence is
        // harmless, a guillotined final word is not. 0.04 was too high —
        // soft word-endings (the trailing "r" of "Sir.", fricatives like
        // "s"/"f"/"th") sit below it, so the cutoff landed mid-word; and
        // 180ms of tail wasn't enough to cover them. Lower bar + longer tail.
        let silenceThreshold: Float = 0.02
        let tailMs = 400
        var lastLoud = -1
        for i in stride(from: envelope.count - 1, through: 0, by: -1) {
            if envelope[i] > silenceThreshold { lastLoud = i; break }
        }
        guard lastLoud >= 0 else { return fallback }
        let endMs = (lastLoud + 1) * chunkMs + tailMs
        let effective = Double(endMs) / 1000.0
        if let fb = fallback { return min(effective, fb) }
        return effective
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
            let overflow = history.count - maxHistory
            // Keep the on-disk replay store in lockstep with in-memory history:
            // drop the retained audio for items that just fell off the end.
            for evicted in history.prefix(overflow) {
                deleteHistoryAudio(id: evicted.id)
            }
            history.removeFirst(overflow)
        }
        return item
    }

    // MARK: - History audio retention (per-item replay store)

    /// Most-recent history item with the given id, or nil. Searches newest-first
    /// so a replayed id (which re-enters history) resolves to its latest entry.
    func findHistory(id: String) -> HistoryItem? {
        history.last(where: { $0.id == id })
    }

    /// Wipe the on-disk replay store. Called once at launch: history lives in
    /// memory and starts empty, so any retained mp3s are orphans from a prior
    /// run and can never be referenced by a replay.
    func purgeHistoryAudioStore() {
        let dir = CaldwellConfig.shared.historyAudioDir
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension.lowercased() == "mp3" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func retainHistoryAudio(id: String, sourceURL: URL) {
        let dir = CaldwellConfig.shared.historyAudioDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(id).mp3")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            NSLog("[AudioQueue] retain history audio failed for \(id): \(error)")
        }
    }

    private func deleteHistoryAudio(id: String) {
        let url = CaldwellConfig.shared.historyAudioDir.appendingPathComponent("\(id).mp3")
        try? FileManager.default.removeItem(at: url)
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
