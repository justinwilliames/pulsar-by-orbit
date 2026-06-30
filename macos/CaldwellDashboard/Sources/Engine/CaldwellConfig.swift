import Foundation

/// Singleton config store. Reads from:
///   1. REPO_ROOT/config.json — muted state, expletives toggle, native voice.
///   2. Environment variables — overrides for the native-voice choice + canon.
///
/// Thread-safe: all mutations go through an NSLock. Call `reload()` after
/// writing config.json to pick up new values without restarting the app.
final class CaldwellConfig: @unchecked Sendable {
    static let shared = CaldwellConfig()

    private let lock = NSLock()
    private var _config: [String: String] = [:]

    // MARK: - Init

    private init() {
        reload()
    }

    // MARK: - Paths

    /// Repo root: honour CALDWELL_REPO_ROOT env var first, then default to
    /// ~/code/caldwell-speak (matches what the install scripts assume).
    var repoRoot: URL {
        if let env = ProcessInfo.processInfo.environment["CALDWELL_REPO_ROOT"],
           !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("code/caldwell-speak")
    }

    var configPath: URL {
        repoRoot.appendingPathComponent("config.json")
    }

    var cacheDir: URL {
        repoRoot.appendingPathComponent("cache")
    }

    var phraseCacheDir: URL {
        cacheDir.appendingPathComponent("phrases")
    }

    /// Per-history-item audio retention store. Distinct from the phrase
    /// (dedupe) cache: EVERY played line is copied here keyed by its history
    /// id so `/history/replay` works for every entry, not just cache-eligible
    /// canon. Lifecycle-coupled to the in-memory history list (wiped at launch,
    /// evicted when an item drops off history) — see AudioQueueActor.
    var historyAudioDir: URL {
        cacheDir.appendingPathComponent("history")
    }

    // MARK: - Config values

    var isMuted: Bool {
        let val = lock.withLock { _config["CALDWELL_MUTED"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    /// Whether Potty Mouth mode is on. Default OFF (Polite). When ON, canon
    /// picks from the potty pool and bespoke /speak lines are delivered as-is
    /// (no scrubbing). When OFF, bespoke lines are scrubbed clean before being
    /// cached or spoken, making Polite authoritative regardless of caller text.
    var expletivesEnabled: Bool {
        let val = lock.withLock { _config["CALDWELL_EXPLETIVES"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    /// The user's chosen local (free-mode) voice. Empty = auto (Daniel Enhanced
    /// when installed, else basic Daniel). Set via the Settings voice picker.
    var nativeVoiceChoice: String {
        (lock.withLock { _config["CALDWELL_NATIVE_VOICE"] }
            ?? ProcessInfo.processInfo.environment["CALDWELL_NATIVE_VOICE"]
            ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Whether cached "canon" pings are allowed — the free notification-style
    /// turn-end lines plus the budget-saver downgrade. Off = bespoke-only: only
    /// the model's composed lines speak (richer, fewer, and they cost credit).
    /// Default on preserves today's behaviour.
    var canonEnabled: Bool {
        let val = lock.withLock { _config["CALDWELL_CANON_ENABLED"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    /// Whether the animated floating Pulsar head is shown on screen while it
    /// speaks. Default ON preserves today's behaviour. When OFF, the floating
    /// window is never created/shown (the voice still plays).
    var floatingHeadEnabled: Bool {
        let val = lock.withLock { _config["CALDWELL_FLOATING_HEAD"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    // MARK: - Mutate + reload

    /// Re-read config.json from disk. Call after any write.
    func reload() {
        guard let data = try? Data(contentsOf: configPath),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }   // unreadable/malformed → keep last-known, never blank
        // Coerce per-key so one non-string value can't nuke the whole config
        // (a bad hand-edit must not silently revert mute or persona).
        var coerced: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { coerced[k] = s }
            else if let b = v as? Bool { coerced[k] = b ? "1" : "0" }
            else if let n = v as? NSNumber { coerced[k] = n.stringValue }
        }
        lock.withLock { _config = coerced }
    }

    /// Write a single key back to config.json and reload.
    func set(_ key: String, value: String) throws {
        var current: [String: String] = [:]
        if let data = try? Data(contentsOf: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            current = json
        }
        current[key] = value
        let data = try JSONSerialization.data(withJSONObject: current, options: .prettyPrinted)
        try data.write(to: configPath)
        reload()
    }
}

// Convenience — avoids `defer` boilerplate.
extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
