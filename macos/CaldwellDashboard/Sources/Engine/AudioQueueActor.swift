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
    /// When this entry entered the queue. Drives the staleness purge so a line
    /// that has waited too long behind a backed-up queue is dropped rather than
    /// blocking newer lines. Set at enqueue time.
    var enqueuedAt: Date = Date()
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

/// Single-resume guard for a process-wait continuation. `Process.termination-
/// Handler` fires on a Foundation-owned thread (off the actor), and the cutoff
/// path may also try to finish, so the resume must be exactly-once and thread-
/// safe. A plain lock makes it so without blocking any cooperative-pool thread.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    var cont: CheckedContinuation<Void, Error>?

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed, let c = cont else { return }
        resumed = true
        cont = nil
        c.resume()
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed, let c = cont else { return }
        resumed = true
        cont = nil
        c.resume(throwing: error)
    }
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

    // Resolved URLs for entries whose fetch completed (possibly BEFORE the
    // worker dequeues/waits on them). The worker reads here both at dequeue
    // (pre-resolved pickup) and after its continuation resumes.
    private var resolvedURLs: [String: URL] = [:]

    // Ids whose fetch FAILED before/while the worker handles them. Mirrors
    // resolvedURLs for the failure case so a markFailed that fires before the
    // worker waits isn't a lost wakeup (worker would otherwise park 30s).
    private var failedIds: Set<String> = []

    // MARK: - In-flight sub-agent drones

    /// One in-flight sub-agent: its drone category + the last time we heard from
    /// it (start, or any `--agent` line it spoke). `lastSeen` powers the staleness
    /// sweep so a dropped SubagentStop hook can't leave a ghost drone orbiting
    /// forever.
    private struct InFlightDrone {
        var category: String
        var lastSeen: Date
    }

    /// Currently in-flight sub-agents, keyed by agentId. Populated by
    /// /subagent/start, refreshed by every tagged speak line, cleared by
    /// /subagent/stop or the staleness sweep.
    private var inFlight: [String: InFlightDrone] = [:]

    /// An in-flight drone is evicted if nothing has refreshed it within this
    /// window — covers a lost SubagentStop hook (the overlay would otherwise lie).
    static let droneStaleAfter: TimeInterval = 90

    /// Record a newly-spawned sub-agent as in-flight under its drone category.
    func addInFlightDrone(id: String, category: String) {
        inFlight[id] = InFlightDrone(category: category, lastSeen: Date())
    }

    /// Remove a finished sub-agent from the in-flight set.
    func removeInFlightDrone(id: String) {
        inFlight.removeValue(forKey: id)
    }

    /// Refresh an in-flight drone's `lastSeen` by agentId — so an actively
    /// narrating drone is never swept. No-op if the id isn't tracked (start is
    /// the only spawn path; a tagged line never resurrects a drone).
    func touchInFlightDrone(id: String) {
        guard inFlight[id] != nil else { return }
        inFlight[id]?.lastSeen = Date()
    }

    /// Refresh `lastSeen` for every in-flight drone of a given category. The
    /// `/speak --agent <cat>` path carries only the category (not an agentId),
    /// so a narrating drone keeps all same-category siblings alive for the line.
    func touchInFlightDrones(category: String) {
        let cat = category.lowercased()
        let now = Date()
        for (id, d) in inFlight where d.category == cat {
            inFlight[id]?.lastSeen = now
        }
    }

    /// Snapshot of the current in-flight drones (agentId → category).
    func inFlightDronesSnapshot() -> [String: String] {
        inFlight.mapValues(\.category)
    }

    /// Evict any in-flight drone not seen within `droneStaleAfter`. Returns the
    /// post-sweep snapshot ONLY when something was evicted (so the caller can
    /// re-broadcast); nil when nothing changed (no needless broadcast).
    func sweepStaleDrones(now: Date = Date()) -> [String: String]? {
        let stale = inFlight.filter { now.timeIntervalSince($0.value.lastSeen) > Self.droneStaleAfter }
        guard !stale.isEmpty else { return nil }
        for id in stale.keys {
            inFlight.removeValue(forKey: id)
            NSLog("[AudioQueue] 🫥 swept stale drone \(id) (no Stop within \(Int(Self.droneStaleAfter))s)")
        }
        return inFlight.mapValues(\.category)
    }

    // MARK: - Public API

    /// Maximum number of entries allowed to wait behind the currently-playing
    /// one. A burst of lines (e.g. a roll call of sub-agents) should all queue
    /// and play in order, so this is generous — only a genuinely huge backlog
    /// is refused.
    static let maxWaitingDepth = 50

    /// A WAITING entry older than this (never the currently-playing one) is a
    /// never-said straggler — purged so a backed-up queue self-clears and new
    /// lines always get in.
    static let staleWaiterSeconds: TimeInterval = 60

    /// Add an entry to the queue. Returns queue depth after insertion, or
    /// nil if the queue was full and the entry was dropped.
    func enqueue(_ entry: AudioEntry) -> Int? {
        // Self-clear before the cap check: drop any waiting entries that have
        // sat unplayed too long, so a stuck/backed-up queue never permanently
        // blocks future lines.
        purgeStaleWaiters()

        if queue.count >= Self.maxWaitingDepth {
            NSLog("[AudioQueue] ✋ dropped '\(entry.text.prefix(60))' — busy (waiting=\(queue.count))")
            return nil
        }
        var stamped = entry
        stamped.enqueuedAt = Date()
        queue.append(stamped)
        if !workerRunning {
            workerRunning = true
            Task { await runWorker() }
        }
        return queue.count
    }

    /// Drop WAITING entries whose `enqueuedAt` is older than `staleWaiterSeconds`.
    /// Only touches `queue` (waiters) — never `currentEntry` (the line actually
    /// playing). Returns the number purged.
    @discardableResult
    private func purgeStaleWaiters(now: Date = Date()) -> Int {
        let before = queue.count
        queue.removeAll { now.timeIntervalSince($0.enqueuedAt) > Self.staleWaiterSeconds }
        let purged = before - queue.count
        if purged > 0 {
            NSLog("[AudioQueue] 🧹 purged \(purged) stale waiter(s) (>\(Int(Self.staleWaiterSeconds))s unplayed)")
        }
        return purged
    }

    /// Called by the background TTS fetch task when audio is ready.
    func markReady(id: String, url: URL) {
        resolvedURLs[id] = url
        let waiting = readyContinuations[id] != nil
        readyContinuations[id]?.resume()
        readyContinuations.removeValue(forKey: id)
        NSLog("[AudioQueue] ✅ markReady \(id) (worker \(waiting ? "WAS waiting — resumed" : "not yet waiting — stored"))")
    }

    /// Called by the background TTS fetch task on failure.
    func markFailed(id: String) {
        let waiting = readyContinuations[id] != nil
        failedIds.insert(id)
        readyContinuations[id]?.resume()
        readyContinuations.removeValue(forKey: id)
        NSLog("[AudioQueue] ❌ markFailed \(id) (worker \(waiting ? "WAS waiting — resumed" : "not yet waiting — flagged"))")
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

    /// Breath between consecutive lines so a roll call sounds like a conversation
    /// with pauses, not a run-on. Applied BETWEEN lines only — never before the
    /// first, never when nothing follows.
    static let interLineGapSeconds: Double = 1.0

    private func runWorker() async {
        NSLog("[AudioQueue] 🔁 runWorker START (queue=\(queue.count))")
        var firstLine = true
        while !queue.isEmpty {
            // Sweep stale waiters each iteration so a straggler can't sit forever
            // when nothing new is being enqueued to trigger the enqueue-time purge.
            purgeStaleWaiters()
            guard !queue.isEmpty else { break }

            // A clear ~1s breath BETWEEN lines (not before the first).
            if !firstLine {
                try? await Task.sleep(nanoseconds: UInt64(Self.interLineGapSeconds * 1_000_000_000))
            }
            firstLine = false

            var entry = queue.removeFirst()
            currentEntry = entry

            // Resolution may have raced ahead of us — pick up a URL (or a failure)
            // that landed BEFORE we dequeued this entry. This is the common case
            // in a burst: every later entry resolves while line 1 plays, long
            // before the worker reaches it.
            if entry.audioURL == nil, !entry.fetchFailed {
                if let pre = resolvedURLs.removeValue(forKey: entry.id) {
                    entry.audioURL = pre
                } else if failedIds.remove(entry.id) != nil {
                    entry.fetchFailed = true
                }
            }

            let source: String
            if entry.audioURL != nil {
                source = entry.fetchFailed ? "fetchFailed" : "pre-resolved/cached"
            } else {
                source = "nil — awaiting fetch"
            }
            NSLog("[AudioQueue] ⬇️ dequeue \(entry.id) '\(entry.text.prefix(40))' audioURL=\(source) remaining=\(queue.count)")

            // Wait for the fetch ONLY if the URL still isn't available and the
            // fetch hasn't already failed. Race-free: the pre-resolved/pre-failed
            // pickup above and this registration run in the SAME synchronous
            // actor region (no await between them), so a markReady/markFailed
            // can't slip in unseen between the check and the wait.
            if entry.audioURL == nil && !entry.fetchFailed {
                let entryId = entry.id
                NSLog("[AudioQueue] ⏳ \(entryId) not yet resolved — waiting for fetch")
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
                // Continuation resumed (markReady, markFailed, or watchdog) —
                // read whichever outcome landed.
                if let url = resolvedURLs.removeValue(forKey: entry.id) {
                    entry.audioURL = url
                } else {
                    failedIds.remove(entry.id)
                    entry.fetchFailed = true
                }
                NSLog("[AudioQueue] ▶️resume \(entryId) → \(entry.audioURL != nil ? "have URL, playing" : "no URL, native fallback")")
            }

            await playEntry(entry)
            currentEntry = nil
            NSLog("[AudioQueue] ⏹ done \(entry.id); \(queue.count) waiting")
        }
        currentEntry = nil
        // Clear the running flag LAST, then re-check: an enqueue that raced in
        // after the `while` test saw workerRunning==true and did NOT spawn a new
        // worker, so its entry would sit unplayed forever. Re-arm if so. (This is
        // the lost-worker race that stalls a burst with entries still queued.)
        workerRunning = false
        if !queue.isEmpty {
            NSLog("[AudioQueue] ♻️ runWorker re-arming — \(queue.count) enqueued during shutdown")
            workerRunning = true
            await runWorker()
            return
        }
        NSLog("[AudioQueue] 🔚 runWorker END (queue empty)")
    }

    /// Watchdog: if a fetch never reports back, free the worker.
    /// Idempotent — safe if markReady/markFailed already cleared the entry.
    func timeoutEntry(id: String) {
        guard let cont = readyContinuations.removeValue(forKey: id) else { return }
        NSLog("[AudioQueue] ⏱ fetch timeout for \(id) after \(Self.fetchWaitTimeoutSeconds)s — skipping")
        cont.resume()
    }

    /// Terminate a process if it's still running (effective-end cutoff). Actor-
    /// isolated so it's serialized with the rest of the queue's process handling.
    private func terminateIfRunning(_ process: Process) {
        if process.isRunning { process.terminate() }
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
            // Same non-blocking wait as playEntry: resume from the termination
            // handler, never from a blocking `waitUntilExit()` on a pool thread.
            let box = ContinuationBox()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.cont = cont
                process.terminationHandler = { _ in box.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    box.resume(throwing: error)
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
            await broadcastIdleIfQueueEmpty()
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
            // Wait for afplay WITHOUT blocking a cooperative-pool thread.
            //
            // ROOT CAUSE of the "stops after 2 lines" stall: the old code waited
            // on `Task.detached { process.waitUntilExit() }`. `waitUntilExit()` is
            // a BLOCKING syscall, and `Task.detached` runs on Swift's cooperative
            // thread pool (sized to core count). Every play — plus each /speak's
            // detached `say` synthesis — parked a pool thread on a blocking wait.
            // A burst of 7 lines exhausted the pool, so the `cont.resume()` task
            // (also detached) could never get scheduled → the worker parked
            // forever with entries still queued and NO further log output. Exactly
            // the observed symptom.
            //
            // Fix: resume the continuation from `process.terminationHandler`
            // (fired by Foundation off the pool) and arm the effective-end cutoff
            // with a NON-blocking `Task.sleep`. A resumeOnce guard makes the two
            // racers (natural exit vs cutoff) safe — the continuation resumes
            // exactly once. No cooperative thread is ever blocked.
            let resumeBox = ContinuationBox()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                resumeBox.cont = cont
                process.terminationHandler = { _ in
                    resumeBox.resume()
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    resumeBox.resume(throwing: error)
                    return
                }
                // Effective-end cutoff: stop afplay before trailing silence.
                if let cutoff = effectiveDuration, cutoff > 0,
                   fileDuration == nil || cutoff < (fileDuration ?? 0) - 0.05 {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(cutoff * 1_000_000_000))
                        await self?.terminateIfRunning(process)
                    }
                }
            }
            NSLog("[AudioQueue] ⏏️ afplay returned for \(entry.id)")
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

        await broadcastIdleIfQueueEmpty()
        let historyItem = recordHistory(entry: entry, duration: effectiveDuration, failed: false)
        await broadcaster.broadcast(
            event: "history_update",
            json: jsonString(historyPayload(for: historyItem, type: entry.isReplay ? "replay" : "speak"))
        )
    }

    /// Broadcast the idle / return-to-Pulsar state ONLY when the roll call is
    /// genuinely over (no more lines queued). Between consecutive queued lines
    /// this is a no-op, so the centre holds the just-finished speaker (its mouth
    /// stilling as the audio ends) and the NEXT line's `voice_active` swaps
    /// straight in — drone → drone, never drone → idle-Pulsar → drone. Pulsar
    /// only returns to centre when the queue is empty.
    private func broadcastIdleIfQueueEmpty() async {
        guard queue.isEmpty else {
            NSLog("[AudioQueue] ↪︎ holding centre — \(queue.count) line(s) still queued (no idle flash)")
            return
        }
        await broadcaster.broadcast(event: "voice_active", json: jsonString(idlePayload(queued: queue.count)))
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
