import Foundation

/// Reconciles locally-observed ElevenLabs character spend with the (laggy)
/// figure ElevenLabs' `/v1/user` subscription endpoint reports.
///
/// Why this exists: `/v1/user`'s `character_count` is eventually-consistent —
/// after a confirmed TTS fetch it can sit unchanged for tens of seconds before
/// catching up. Reproduced directly: a +43-char fetch left the remote counter
/// flat at 287 for ~40s. Relaying that raw made `/usage` report stale numbers
/// right after a fetch (the observed `characters_used:0` then later `287`).
///
/// We, however, know exactly how many characters every successful fetch cost
/// (`text.count`, the single chokepoint being `ElevenLabsClient.fetchTTS`).
/// So we keep a local floor and report `max(remote, baseline + sessionChars)`:
///   • Right after a fetch the remote under-reports → the local floor wins →
///     usage reflects spend immediately.
///   • Once the remote catches up it meets/exceeds the floor → `max` tracks the
///     remote again, which also captures spend from other clients on the key.
///   • On a billing-period rollover (`next_reset_unix` advances) we re-baseline
///     to the fresh remote and drop the prior period's session spend.
///
/// Thread-safety: all state is guarded by an NSLock; methods are safe to call
/// from any thread/actor.
final class UsageTracker: @unchecked Sendable {
    static let shared = UsageTracker()
    private init() {}

    private let lock = NSLock()

    /// Characters we've successfully fetched this process, within the current
    /// billing period.
    private var sessionChars = 0
    /// The `next_reset_unix` we've reconciled against. A change means the
    /// billing period rolled over.
    private var seededReset: Int?
    /// Remote `character_count` captured when we first observed this period —
    /// i.e. spend that predates our local tracking. `nil` until first seed.
    private var baselineRemote: Int?
    /// The monthly `character_limit` from the subscription. Captured so the
    /// adaptive spend gate can read the budget in-memory without a network
    /// round-trip on every /speak. `nil` until first observed.
    private var seededLimit: Int?

    /// Record a successful fetch's character cost. Called once per fetch from
    /// `ElevenLabsClient.fetchTTS`.
    func recordCharacters(_ count: Int) {
        guard count > 0 else { return }
        lock.withLock { sessionChars += count }
    }

    /// Capture the monthly character limit from a subscription reading.
    func recordLimit(_ limit: Int) {
        guard limit > 0 else { return }
        lock.withLock { seededLimit = limit }
    }

    /// In-memory budget snapshot for the adaptive bespoke-spend gate — no
    /// network. `used` is the live local floor (baseline + this session's
    /// spend). Returns nil until both a baseline and a limit have been seen,
    /// in which case the gate fails open (don't gag the voice on missing data).
    func snapshot() -> (used: Int, limit: Int, reset: Int)? {
        lock.withLock {
            guard let reset = seededReset,
                  let base = baselineRemote,
                  let limit = seededLimit else { return nil }
            return (used: base + sessionChars, limit: limit, reset: reset)
        }
    }

    /// Seed the baseline from a remote reading taken before any fetch (e.g. at
    /// startup), so `baseline + sessionChars` never double-counts. No-op once
    /// seeded. Safe to call opportunistically.
    func seedIfNeeded(remoteUsed: Int, remoteReset: Int) {
        lock.withLock {
            guard seededReset == nil else { return }
            seededReset = remoteReset
            baselineRemote = remoteUsed
        }
    }

    /// Reconcile a fresh remote reading with local spend. Returns the figure to
    /// report as `characters_used`.
    func reconcile(remoteUsed: Int, remoteReset: Int) -> Int {
        lock.withLock {
            if seededReset == nil {
                // First observation this process. Adopt remote as the baseline
                // but KEEP any session spend already recorded — during the
                // upstream lag window the remote won't yet include it.
                seededReset = remoteReset
                baselineRemote = remoteUsed
            } else if seededReset != remoteReset {
                // Billing period rolled over: re-baseline, drop prior spend.
                seededReset = remoteReset
                baselineRemote = remoteUsed
                sessionChars = 0
            }
            let floor = (baselineRemote ?? remoteUsed) + sessionChars
            return max(remoteUsed, floor)
        }
    }
}
