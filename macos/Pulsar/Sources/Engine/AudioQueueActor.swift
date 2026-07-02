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
    /// Drone category for the line (nil = Pulsar), so a pending thumbnail renders
    /// the right face. `voice` is a hardcoded "Pulsar" label and can't carry it.
    let agent: String?
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

// MARK: - Live-audio process registry (teardown-safe)

/// Process-global handle to the single live audio child (`afplay` or the `say`
/// fallback). Lives OUTSIDE the actor so app teardown — `applicationWillTerminate`
/// on the main actor — can kill the child SYNCHRONOUSLY without awaiting the
/// actor (the app may `exit()` before an actor hop completes).
///
/// WHY THIS EXISTS: a `Process` spawned by the app is an INDEPENDENT child. When
/// the app process exits, that child (afplay) is NOT auto-killed — it plays the
/// AIFF to completion, so speech outlived the quit. Registering the live child
/// here lets `terminateAll()` stop it the instant the app starts tearing down.
///
/// Thread-safe via a plain lock; the actor registers/clears its `currentProcess`
/// here as it spawns/reaps, and teardown calls `terminateAll()`.
final class LiveAudioProcesses: @unchecked Sendable {
    static let shared = LiveAudioProcesses()
    private let lock = NSLock()
    private var processes: [Process] = []

    func register(_ p: Process) {
        lock.withLock { processes.append(p) }
    }

    func unregister(_ p: Process) {
        lock.withLock { processes.removeAll { $0 === p } }
    }

    /// Synchronously terminate every live audio child. Called from app teardown
    /// so speech never outlives the app. Idempotent + best-effort.
    func terminateAll() {
        let live = lock.withLock { let copy = processes; processes.removeAll(); return copy }
        for p in live where p.isRunning { p.terminate() }
        if !live.isEmpty { NSLog("[Pulsar] 🛑 terminated \(live.count) live audio process(es) on teardown") }
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

    /// Delete a synth temp AIFF for `id` (if any) and drop its resolved/failed
    /// bookkeeping, so an entry removed via ANY path — played, timed out, or
    /// swept as a stale waiter — never leaks its `say`-produced temp file to disk.
    /// The detached synth task writes into NSTemporaryDirectory and only ever
    /// registers the URL via `markReady`; without this, a URL that lands (or has
    /// already landed) in `resolvedURLs` for a dropped entry is never unlinked.
    /// Only removes files under NSTemporaryDirectory — a phrase-cache/history mp3
    /// that reached the queue via a resolved URL is never touched.
    private func discardResolved(id: String) {
        if let url = resolvedURLs.removeValue(forKey: id) {
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).standardized.path
            if url.standardized.path.hasPrefix(tmpDir) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        failedIds.remove(id)
    }

    // MARK: - In-flight sub-agent drones

    /// One in-flight sub-agent: its drone category + the last time we heard from
    /// it (start, or any `--agent` line it spoke). `lastSeen` powers the staleness
    /// sweep so a dropped SubagentStop hook can't leave a ghost drone orbiting
    /// forever.
    private struct InFlightDrone {
        var category: String
        var lastSeen: Date
        /// The Claude Code session that spawned this sub-agent, if the hook
        /// supplied it. Used to session-scope claim-on-speak promotion so a
        /// `--agent` line from session A can't claim session B's generic drone.
        /// nil when the hook didn't carry a session_id — promotion then falls
        /// back to the old cross-session behaviour (best-effort).
        var sessionId: String?
    }

    /// Currently in-flight sub-agents, keyed by agentId. Populated by
    /// /subagent/start, refreshed by every tagged speak line, cleared by
    /// /subagent/stop or the staleness sweep.
    ///
    /// Mutations DON'T persist synchronously — a batch mutation (the sweep or
    /// deferred-removal flush touches many keys in a loop) would otherwise fire
    /// one blocking disk write per key. Instead each mutation marks the store
    /// dirty and schedules a single coalesced write; see `schedulePersist()`.
    private var inFlight: [String: InFlightDrone] = [:] {
        didSet { schedulePersist() }
    }

    /// Agent ids whose /subagent/stop arrived WHILE that drone was the active
    /// speaker (its line still playing/queued). Removal is deferred until the
    /// speech finishes so the user never sees a drone vanish mid-sentence; the
    /// worker fires `flushDeferredRemovals` when the queue drains, and the
    /// staleness sweep is the backstop if a flush is somehow missed.
    private var pendingRemoval: Set<String> = []

    // MARK: - In-flight persistence

    /// Codable mirror of an InFlightDrone for the on-disk store.
    private struct PersistedDrone: Codable {
        var category: String
        var lastSeen: Double  // timeIntervalSince1970 — the REAL lastSeen, never refreshed on load
        var sessionId: String?  // optional — absent in stores written by older builds
    }

    /// Test seam: when set, the in-flight store lives here instead of the real
    /// repo-cache `drones.json`. Lets a test suite persist/restore against a temp
    /// dir without ever touching the live daemon's store. nil in production — the
    /// app never sets it, so behaviour is byte-identical to before.
    var dronesStoreOverrideURL: URL?

    /// Durable store for the in-flight set, so a daemon relaunch/reload doesn't
    /// wipe the swarm (and orphan sub-agents from OTHER sessions whose later
    /// SubagentStop would no-op on a fresh daemon). Repo-cache-relative, matching
    /// the phrase/history stores — no sandbox container to reason about.
    private var dronesStoreURL: URL {
        dronesStoreOverrideURL
            ?? PulsarConfig.shared.cacheDir.appendingPathComponent("drones.json")
    }

    /// True while a coalesced persist is already scheduled, so a burst of
    /// mutations (the sweep / deferred-flush loop touches many keys) collapses
    /// to ONE write instead of one-per-key.
    private var persistScheduled = false

    /// Mark the store dirty and schedule a single coalesced write off the hot
    /// path. The actor hop means any run of synchronous mutations that happen
    /// before the scheduled task is next serviced share one write of the FINAL
    /// state — the per-key sweep/flush loops no longer each hit the disk.
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { [weak self] in await self?.persistInFlight() }
    }

    /// Best-effort atomic write of `inFlight` to disk. The map is tiny, so the
    /// encode+write is cheap; any failure is swallowed so a bad write can never
    /// crash or block the actor. `.atomic` writes to a temp file and renames, so
    /// a crash mid-write can't leave a half-written `drones.json` that would fail
    /// to decode on the next restore. Clears the coalescing flag so the NEXT
    /// mutation schedules a fresh write of whatever state exists then.
    private func persistInFlight() {
        persistScheduled = false
        let snapshot = inFlight.mapValues {
            PersistedDrone(
                category: $0.category,
                lastSeen: $0.lastSeen.timeIntervalSince1970,
                sessionId: $0.sessionId)
        }
        let url = dronesStoreURL
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Restore the in-flight set from disk. Preserves the REAL `lastSeen` for
    /// each drone (NOT refreshed to now) so the 1s sweeper immediately evicts any
    /// drone that has aged past `droneStaleAfter` while the app was closed — the
    /// self-healing property the restart path depends on. Best-effort: a missing
    /// or corrupt store leaves `inFlight` empty. The assignment schedules one
    /// coalesced write of the just-restored state — cheap, and it re-normalises
    /// the file to atomic form.
    func restoreInFlight() {
        guard let data = try? Data(contentsOf: dronesStoreURL),
              let snapshot = try? JSONDecoder().decode([String: PersistedDrone].self, from: data)
        else { return }
        inFlight = snapshot.mapValues {
            InFlightDrone(
                category: $0.category,
                lastSeen: Date(timeIntervalSince1970: $0.lastSeen),
                sessionId: $0.sessionId)
        }
        NSLog("[AudioQueue] ♻️ restored \(inFlight.count) in-flight drone(s) from disk")
    }

    /// An in-flight drone is evicted if nothing has refreshed it within this
    /// window. This is ONLY a backstop for a lost SubagentStop hook — the normal
    /// removal path is /subagent/stop, which fires reliably on completion.
    ///
    /// `lastSeen` is now refreshed ONLY by /subagent/start (spawn) and by an
    /// id-scoped `touchInFlightDrone` — NOT by speech. A speaking `--agent <cat>`
    /// line carries only a category, not a per-agent id, so the old category-wide
    /// refresh kept a GHOST (a drone whose Stop was lost) immortal for as long as
    /// any live sibling of the same category kept speaking. With that refresh
    /// removed, the backstop no longer needs to cover a silent long-runner via
    /// speech, so it can be much shorter: 10 min self-heals a genuinely dropped
    /// Stop quickly while still comfortably outlasting any real gap between a
    /// spawn and its reliable Stop.
    static let droneStaleAfter: TimeInterval = 600

    /// Record a newly-spawned sub-agent as in-flight under its drone category.
    ///
    /// Re-registration safety: an id that re-registers (a duplicate
    /// SubagentStart, or a start racing a not-yet-flushed stop) clears any
    /// PENDING removal for it — otherwise the next `flushDeferredRemovals`
    /// would evict a drone that is demonstrably alive again.
    ///
    /// Label preservation: a double-start for an EXISTING id must not clobber a
    /// category the drone earned by speaking (`promoteInFlightDrone`). We only
    /// overwrite the category when the incoming one is more specific — i.e. the
    /// existing category is still generic (atlas/unknown). A generic incoming
    /// category never demotes a promoted label. `lastSeen` is always refreshed
    /// (the drone is genuinely live right now).
    func addInFlightDrone(id: String, category: String, sessionId: String? = nil) {
        pendingRemoval.remove(id)
        if let existing = inFlight[id] {
            let existingIsGeneric = existing.category == "atlas" || existing.category == "unknown"
            let category = existingIsGeneric ? category : existing.category
            // Keep a session_id once known — a re-register that omits it (older
            // hook, dropped field) must not blank an id we can still scope by.
            let session = sessionId ?? existing.sessionId
            inFlight[id] = InFlightDrone(category: category, lastSeen: Date(), sessionId: session)
        } else {
            inFlight[id] = InFlightDrone(category: category, lastSeen: Date(), sessionId: sessionId)
        }
    }

    /// Remove a finished sub-agent from the in-flight set — UNLESS that drone is
    /// the current active speaker (its `--agent` line is still playing or queued),
    /// in which case removal is DEFERRED until the speech finishes so the user
    /// never sees a drone disappear mid-sentence. Returns true if the drone was
    /// removed now (caller re-broadcasts); false if the removal was deferred
    /// (broadcast happens later, when `flushDeferredRemovals` fires).
    ///
    /// Targeted, not a blanket linger: only a drone whose category matches a
    /// playing/queued line is held back. A deferred removal can't leak — it fires
    /// when the queue drains (worker → `flushDeferredRemovals`), and the staleness
    /// sweep is a hard backstop (a pending id ages out on its real `lastSeen`).
    @discardableResult
    func removeInFlightDrone(id: String) -> Bool {
        guard inFlight[id] != nil else {
            pendingRemoval.remove(id)
            return false
        }
        if isDroneSpeaking(id: id) {
            pendingRemoval.insert(id)
            NSLog("[AudioQueue] ⏸ deferred removal of drone \(id) — its line is still speaking")
            return false
        }
        inFlight.removeValue(forKey: id)
        pendingRemoval.remove(id)
        return true
    }

    /// True if the drone `id`'s category is the currently-playing line's category
    /// OR matches any still-queued line — i.e. its speech is live or imminent, so
    /// removing it now would cut the drone off mid-sentence.
    private func isDroneSpeaking(id: String) -> Bool {
        guard let category = inFlight[id]?.category else { return false }
        if currentEntry?.agentCategory == category { return true }
        return queue.contains { $0.agentCategory == category }
    }

    /// Fire any deferred drone removals whose speech has now ended. Called by the
    /// worker when the queue drains. Returns the post-flush snapshot ONLY when
    /// something was actually removed (so the caller can re-broadcast); nil when
    /// nothing was pending or nothing became flushable.
    func flushDeferredRemovals() -> [String: String]? {
        guard !pendingRemoval.isEmpty else { return nil }
        var removedAny = false
        for id in pendingRemoval {  // Set is a value type — iterating a stable copy while mutating is safe
            // Only flush ids that are no longer speaking — a fresh line for the
            // same category may have arrived after the stop, so re-check.
            if inFlight[id] == nil {
                pendingRemoval.remove(id)
                continue
            }
            if !isDroneSpeaking(id: id) {
                inFlight.removeValue(forKey: id)
                pendingRemoval.remove(id)
                removedAny = true
                NSLog("[AudioQueue] ▶︎ flushed deferred removal of drone \(id) — speech ended")
            }
        }
        return removedAny ? inFlight.mapValues(\.category) : nil
    }

    /// Refresh an in-flight drone's `lastSeen` by agentId — so an actively
    /// narrating drone is never swept. No-op if the id isn't tracked (start is
    /// the only spawn path; a tagged line never resurrects a drone).
    func touchInFlightDrone(id: String) {
        guard inFlight[id] != nil else { return }
        inFlight[id]?.lastSeen = Date()
    }

    /// Claim-on-speak promotion. A sub-agent can only reveal its true drone
    /// category by SPEAKING (`say.sh --agent X`) — the SubagentStart hook carries
    /// only `agent_type`, so every generic worker registers as `atlas`/`unknown`.
    /// When such a line arrives, promote ONE generic in-flight drone's PRESENCE to
    /// category X so the orbiting swarm shows the real character, not a wall of
    /// identical atlases.
    ///
    /// Returns true when presence is consistent with X afterwards — either a drone
    /// of category X already existed (no dupe made) or one was promoted — so the
    /// caller knows whether to re-broadcast. Returns false when nothing changed
    /// (empty/"pulsar" category, or no generic drone available to claim).
    ///
    /// At most ONE promotion per call (the "claim"); prefers the most-recently-
    /// registered generic drone (largest `lastSeen`), matching the intuition that
    /// the newest just-spawned worker is the one now speaking.
    func promoteInFlightDrone(toCategory category: String, sessionId: String? = nil) -> Bool {
        let trimmed = category.trimmingCharacters(in: .whitespaces).lowercased()
        // The centre (Pulsar) and an empty tag are never orbit drones — nothing
        // to promote.
        guard !trimmed.isEmpty, trimmed != "pulsar" else { return false }

        // Already correctly labelled somewhere in the swarm → presence consistent,
        // no dupe, nothing mutated → return false so the caller skips the broadcast.
        if inFlight.contains(where: { $0.value.category == trimmed }) {
            return false
        }

        // Session-scoped claim: a `--agent X` line runs INSIDE one sub-agent, so
        // the drone it's claiming should be a generic one from the SAME session.
        // Prefer that; only fall back to a cross-session generic when the session
        // is unknown or has no generic drone left. This stops session A's line
        // from stealing session B's atlas. Within a candidate set, still take the
        // most-recently-registered (largest lastSeen) — the newest just-spawned
        // worker is the likeliest speaker.
        func newestGeneric(_ pred: (InFlightDrone) -> Bool) -> String? {
            inFlight
                .filter { ($0.value.category == "atlas" || $0.value.category == "unknown") && pred($0.value) }
                .max(by: { $0.value.lastSeen < $1.value.lastSeen })?
                .key
        }

        let id: String?
        if let sessionId, !sessionId.isEmpty {
            // Same-session first; cross-session (incl. session-less drones) only
            // if the speaking session has no generic of its own.
            id = newestGeneric { $0.sessionId == sessionId } ?? newestGeneric { _ in true }
        } else {
            id = newestGeneric { _ in true }
        }
        guard let id else { return false }

        inFlight[id]?.category = trimmed
        NSLog("[AudioQueue] 🎭 promoted drone \(id) → \(trimmed) (claim-on-speak\(sessionId.map { ", session \($0.prefix(8))" } ?? ""))")
        return true
    }

    // NOTE: the old `touchInFlightDrones(category:)` — a category-wide `lastSeen`
    // refresh driven by every `/speak --agent <cat>` line — was REMOVED. It made
    // a ghost drone (one whose SubagentStop was lost) immortal: any live sibling
    // of the same category speaking kept refreshing the ghost too, so it never
    // aged out. A speaking line carries only a category, not a per-agent id, so
    // there is no reliable way to id-scope it. Drone liveness now rests solely on
    // a reliable SubagentStop plus the shorter `droneStaleAfter` backstop sweep.

    /// Snapshot of the current in-flight drones (agentId → category).
    func inFlightDronesSnapshot() -> [String: String] {
        inFlight.mapValues(\.category)
    }

    // MARK: - Test seams (in-flight)
    //
    // These exist ONLY to let the test suite drive the drone lifecycle without
    // spinning up the real audio worker (which spawns `afplay`/`say`). They are
    // never called by the app. Kept `internal` so `@testable import` reaches them.

    /// Force a "currently speaking" category so `isDroneSpeaking` reports live —
    /// the same signal a playing `--agent <cat>` line gives, without playback.
    func _test_setSpeakingCategory(_ category: String?) {
        currentEntry = category.map {
            AudioEntry(
                id: "test-current", text: "", voiceId: "", voiceLabel: "",
                createdAt: Date(), channel: nil, priority: false, fullText: "",
                isReplay: false, agentCategory: $0)
        }
    }

    /// Enqueue a bare marker entry carrying only an agentCategory, so a
    /// still-queued same-category line keeps a drone "speaking" for deferral tests.
    func _test_appendQueuedCategory(_ category: String) {
        queue.append(AudioEntry(
            id: "test-queued-\(category)-\(queue.count)", text: "", voiceId: "",
            voiceLabel: "", createdAt: Date(), channel: nil, priority: false,
            fullText: "", isReplay: false, agentCategory: category))
    }

    /// The lastSeen for an id, for asserting restore/round-trip fidelity.
    func _test_lastSeen(id: String) -> Date? { inFlight[id]?.lastSeen }

    /// Current waiting-queue depth, for asserting `muteNow` drops queued lines.
    func _test_queueDepth() -> Int { queue.count }

    /// Whether an id is currently marked pending-removal (deferred).
    func _test_isPending(id: String) -> Bool { pendingRemoval.contains(id) }

    /// Point the drone persistence store at a test-owned URL (actor-isolated set).
    func setDronesStoreOverride(_ url: URL?) { dronesStoreOverrideURL = url }

    /// Synchronously flush the in-flight set to disk, bypassing the coalesced
    /// `schedulePersist` timing so a test can restore immediately afterwards
    /// without racing the scheduled write. Writes the exact same format.
    func flushPersistForTests() { persistInFlight() }

    /// Evict any in-flight drone not seen within `droneStaleAfter`. Returns the
    /// post-sweep snapshot ONLY when something was evicted (so the caller can
    /// re-broadcast); nil when nothing changed (no needless broadcast).
    func sweepStaleDrones(now: Date = Date()) -> [String: String]? {
        let stale = inFlight.filter { now.timeIntervalSince($0.value.lastSeen) > Self.droneStaleAfter }
        guard !stale.isEmpty else { return nil }
        // Idempotent removal: only broadcast when a drone was ACTUALLY present
        // and removed this call. The 1Hz sweep and the worker's
        // flushDeferredRemovals can target overlapping ids; if a flush already
        // removed one, `removeValue` returns nil here and we must NOT re-broadcast
        // an identical set (the double broadcast is what flickers the fade).
        var removedAny = false
        for id in stale.keys {
            if inFlight.removeValue(forKey: id) != nil {
                removedAny = true
                NSLog("[AudioQueue] 🫥 swept stale drone \(id) (no Stop within \(Int(Self.droneStaleAfter))s)")
            }
            pendingRemoval.remove(id)  // backstop: a pending id that ages out is cleared here too
        }
        return removedAny ? inFlight.mapValues(\.category) : nil
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
        var dropped: [AudioEntry] = []
        queue.removeAll { entry in
            let stale = now.timeIntervalSince(entry.enqueuedAt) > Self.staleWaiterSeconds
            if stale { dropped.append(entry) }
            return stale
        }
        let purged = dropped.count
        if purged > 0 {
            // Drop each straggler's resolved/failed bookkeeping and unlink any
            // synth temp AIFF it already produced, so a purged waiter never
            // leaks its `say` output to disk. A late markReady for one of these
            // ids self-cleans there too (the id is no longer a live waiter).
            for entry in dropped {
                readyContinuations.removeValue(forKey: entry.id)
                discardResolved(id: entry.id)
            }
            NSLog("[AudioQueue] 🧹 purged \(purged) stale waiter(s) (>\(Int(Self.staleWaiterSeconds))s unplayed)")
        }
        return purged
    }

    /// Called by the background TTS fetch task when audio is ready.
    func markReady(id: String, url: URL) {
        // The synth task can land AFTER the worker already dropped this entry
        // (timed out, or swept as a stale waiter). If the id is no longer a
        // live waiter and isn't the currently-playing entry, its temp AIFF is
        // an orphan — unlink it now instead of storing it in resolvedURLs where
        // nothing would ever delete it. This is the disk-leak-per-line fix.
        let isLiveWaiter = readyContinuations[id] != nil || queue.contains(where: { $0.id == id })
        let isPlaying = currentEntry?.id == id
        guard isLiveWaiter || isPlaying else {
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).standardized.path
            if url.standardized.path.hasPrefix(tmpDir) {
                try? FileManager.default.removeItem(at: url)
            }
            NSLog("[AudioQueue] 🧹 markReady \(id) for a dropped entry — orphan AIFF unlinked")
            return
        }
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

    /// Immediate mute: terminate the currently-playing audio process (afplay or
    /// the `say` fallback) RIGHT NOW so a mid-line mute goes quiet within a
    /// fraction of a second, and drop every still-queued waiter so nothing else
    /// sounds while muted. The worker's per-entry mute-gate (`playEntry` /
    /// `speakNative`) is the belt to this braces — it silences any line that was
    /// already dequeued/in-flight when the mute landed.
    ///
    /// Killing `currentProcess` resumes the worker's playback continuation via the
    /// process terminationHandler; the worker then finds the queue empty (we clear
    /// it here) and idles. Unmute simply resumes normal behaviour for new lines.
    func muteNow() {
        currentProcess?.terminate()
        if !queue.isEmpty {
            // Unlink any synth temp AIFF the dropped waiters already produced, and
            // clear their resolved/failed bookkeeping, so a mute never leaks temp
            // files to disk (mirrors purgeStaleWaiters' cleanup).
            for entry in queue {
                readyContinuations.removeValue(forKey: entry.id)
                discardResolved(id: entry.id)
            }
            NSLog("[AudioQueue] 🔇 muteNow — killed current playback + dropped \(queue.count) queued line(s)")
            queue.removeAll()
        } else {
            NSLog("[AudioQueue] 🔇 muteNow — killed current playback")
        }
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
                priority: currentEntry.priority,
                agent: currentEntry.agentCategory
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
                priority: entry.priority,
                agent: entry.agentCategory
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

            // After EACH line finishes, fire any deferred drone removals whose
            // speech has now ended. Tying this to per-line completion (not just a
            // fully-empty queue) matters in a live session: Pulsar speaks every
            // turn, so the queue may never truly empty — a deferred drone whose
            // own category has no further queued line must still be released here,
            // or continuous other traffic would starve it until the 600s sweep.
            // `flushDeferredRemovals` re-checks isDroneSpeaking per pending id, so
            // a drone with a still-queued same-category line correctly stays.
            if let trimmed = flushDeferredRemovals() {
                let json = (try? JSONSerialization.data(withJSONObject: ["drones": trimmed]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"drones\":{}}"
                await broadcaster.broadcast(event: "drones_in_flight", json: json)
            }

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
        // The worker resumes into its no-URL fallback and drops this entry; if a
        // synth URL had already raced into resolvedURLs it would otherwise leak,
        // so unlink it here. A synth that lands LATER self-cleans in markReady
        // (the id is no longer a live waiter once the worker moves past it).
        cont.resume()
        // Note: the resumed worker consumes resolvedURLs[id] itself when a URL is
        // present (it plays that entry). discardResolved only fires if the URL is
        // still unclaimed after the worker's synchronous post-resume read — which
        // can't interleave here (this runs before resume returns to the worker).
    }

    /// Terminate a process if it's still running (effective-end cutoff). Actor-
    /// isolated so it's serialized with the rest of the queue's process handling.
    private func terminateIfRunning(_ process: Process) {
        if process.isRunning { process.terminate() }
    }

    // MARK: - Playback

    /// Zero-cost voice fallback: speak `text` via the macOS `say` command in a
    /// British voice when ElevenLabs synthesis is unavailable, so Pulsar never
    /// goes silent on a failed fetch. Voice overridable via the
    /// PULSAR_FALLBACK_VOICE env var (default "Daniel"). Best-effort — launch
    /// errors are logged and swallowed. Reuses `currentProcess` so --skip can
    /// interrupt it like any premium line.
    private func speakNative(_ text: String) async {
        // Honour the global mute exactly like the premium voice. Mute is already
        // enforced upstream at /speak (muted requests never enqueue), so muted
        // lines normally never reach here — but this guard also catches the
        // race where the user mutes mid-flight, after a line was queued. A mute
        // silences Daniel, not just ElevenLabs.
        guard !PulsarConfig.shared.isMuted else {
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
        // Register the live child so app teardown can kill it synchronously.
        LiveAudioProcesses.shared.register(process)
        defer { LiveAudioProcesses.shared.unregister(process) }
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
        // Mute-gate: a line can reach here AFTER the user muted (it was already
        // dequeued / mid-resolve when the mute landed, so it never hit the
        // upstream /speak enqueue guard). Muting is an immediate, real mute — so
        // drop this line silently rather than play into a muted session. `muteNow`
        // handles the ONE line that was already sounding through afplay; this
        // guard handles the next-in-line that the killed worker would otherwise
        // advance to.
        guard !PulsarConfig.shared.isMuted else {
            NSLog("[AudioQueue] 🔇 playEntry \(entry.id) suppressed — muted")
            // Unlink a temp AIFF this entry produced so a muted drop doesn't leak.
            if let url = entry.audioURL {
                let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).standardized.path
                if url.standardized.path.hasPrefix(tmpDir) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            await broadcastIdleIfQueueEmpty()
            return
        }

        guard !entry.fetchFailed, let audioURL = entry.audioURL else {
            // ElevenLabs synthesis was unavailable (missing/invalid key,
            // exhausted quota, or invalid audio). Rather than go mute, speak the
            // line through the macOS `say` command in a British voice — free, no
            // ElevenLabs spend. Mute is enforced upstream at /speak (muted
            // requests never enqueue), so reaching here means the user wants to
            // hear Pulsar and only the premium voice failed.
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
        // Register the live child so app teardown can kill it synchronously —
        // otherwise afplay outlives the quit and keeps talking.
        LiveAudioProcesses.shared.register(process)
        defer { LiveAudioProcesses.shared.unregister(process) }

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
        let dir = PulsarConfig.shared.historyAudioDir
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension.lowercased() == "mp3" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func retainHistoryAudio(id: String, sourceURL: URL) {
        let dir = PulsarConfig.shared.historyAudioDir
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
        let url = PulsarConfig.shared.historyAudioDir.appendingPathComponent("\(id).mp3")
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
