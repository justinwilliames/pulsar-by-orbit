import Foundation

/// Reconciles locally-observed ElevenLabs character spend with the (laggy)
/// figure ElevenLabs' `/v1/user` subscription endpoint reports.
///
/// Why this exists: `/v1/user`'s `character_count` is eventually-consistent —
/// after a confirmed TTS fetch it can sit unchanged for tens of seconds before
/// catching up. We know exactly how many characters every successful fetch cost
/// (`text.count`, the single chokepoint being `ElevenLabsClient.fetchTTS`), so
/// we keep a local floor and report `max(remote, baseline + sessionChars)`.
///
/// Persistence (added per the team review — Han): the baseline/limit/reset and
/// session spend are written to an Application Support sidecar and LOADED at
/// init, so the adaptive spend gate is seeded the instant the process starts.
/// Without this the gate's `snapshot()` returned nil on every cold launch and
/// failed OPEN during the loud start-up ping burst — silent uncontrolled spend.
/// A separate append-only ledger records every play decision (engine, chars,
/// decision) so spend is auditable and the "free/local" claim is provable.
///
/// Thread-safety: all state is guarded by an NSLock; methods are safe to call
/// from any thread/actor.
final class UsageTracker: @unchecked Sendable {
    static let shared = UsageTracker()

    private let lock = NSLock()
    private let ledgerLock = NSLock()

    private var sessionChars = 0
    private var seededReset: Int?
    private var baselineRemote: Int?
    private var seededLimit: Int?

    private static let supportDir: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("caldwell-speak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let stateURL = supportDir.appendingPathComponent("usage-state.json")
    private let ledgerURL = supportDir.appendingPathComponent("spend-ledger.jsonl")

    private init() { load() }

    // MARK: - Public

    func recordCharacters(_ count: Int) {
        guard count > 0 else { return }
        lock.withLock { sessionChars += count; persistLocked() }
    }

    func recordLimit(_ limit: Int) {
        guard limit > 0 else { return }
        lock.withLock { seededLimit = limit; persistLocked() }
    }

    /// In-memory budget snapshot for the adaptive bespoke-spend gate — no
    /// network. Now non-nil immediately after launch when a prior period was
    /// persisted, so the gate no longer fails open on the cold-cache burst.
    func snapshot() -> (used: Int, limit: Int, reset: Int)? {
        lock.withLock {
            guard let reset = seededReset,
                  let base = baselineRemote,
                  let limit = seededLimit else { return nil }
            return (used: base + sessionChars, limit: limit, reset: reset)
        }
    }

    func seedIfNeeded(remoteUsed: Int, remoteReset: Int) {
        lock.withLock {
            guard seededReset == nil else { return }
            seededReset = remoteReset
            baselineRemote = remoteUsed
            persistLocked()
        }
    }

    func reconcile(remoteUsed: Int, remoteReset: Int) -> Int {
        lock.withLock {
            if seededReset == nil {
                seededReset = remoteReset
                baselineRemote = remoteUsed
            } else if seededReset != remoteReset {
                seededReset = remoteReset
                baselineRemote = remoteUsed
                sessionChars = 0
            }
            persistLocked()
            let floor = (baselineRemote ?? remoteUsed) + sessionChars
            return max(remoteUsed, floor)
        }
    }

    /// Append a play decision to the audit ledger (engine, char-cost, decision).
    /// Best-effort, off the budget-lock-critical path. `chars` is the line's
    /// length — only billed for the "bespoke" (ElevenLabs) decision.
    func logSpend(engine: String, chars: Int, decision: String) {
        let line: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "engine": engine, "chars": chars, "decision": decision,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line),
              let s = String(data: data, encoding: .utf8) else { return }
        let row = s + "\n"
        ledgerLock.withLock {
            if let fh = try? FileHandle(forWritingTo: ledgerURL) {
                fh.seekToEndOfFile()
                fh.write(Data(row.utf8))
                try? fh.close()
            } else {
                try? row.write(to: ledgerURL, atomically: true, encoding: .utf8)
            }
            trimLedgerLocked()
        }
    }

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.withLock {
            sessionChars = (obj["sessionChars"] as? Int) ?? 0
            seededReset = obj["seededReset"] as? Int
            baselineRemote = obj["baselineRemote"] as? Int
            seededLimit = obj["seededLimit"] as? Int
        }
    }

    /// Caller MUST hold `lock`. Atomic write so a crash mid-save can't corrupt it.
    private func persistLocked() {
        var obj: [String: Any] = ["sessionChars": sessionChars]
        if let r = seededReset { obj["seededReset"] = r }
        if let b = baselineRemote { obj["baselineRemote"] = b }
        if let l = seededLimit { obj["seededLimit"] = l }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// Caller MUST hold `ledgerLock`. Keep the ledger bounded — past ~2MB,
    /// retain the last 4000 lines.
    private func trimLedgerLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: ledgerURL.path),
              let size = attrs[.size] as? Int, size > 2_000_000,
              let content = try? String(contentsOf: ledgerURL, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 4000 else { return }
        let kept = lines.suffix(4000).joined(separator: "\n") + "\n"
        try? kept.write(to: ledgerURL, atomically: true, encoding: .utf8)
    }
}
