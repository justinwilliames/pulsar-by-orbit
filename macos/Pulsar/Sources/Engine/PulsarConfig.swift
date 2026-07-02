import Foundation

/// Singleton config store. Reads from:
///   1. REPO_ROOT/config.json — muted state, expletives toggle, native voice.
///   2. Environment variables — overrides for the native-voice choice + canon.
///
/// Thread-safe: all mutations go through an NSLock. Call `reload()` after
/// writing config.json to pick up new values without restarting the app.
final class PulsarConfig: @unchecked Sendable {
    static let shared = PulsarConfig()

    private let lock = NSLock()
    private var _config: [String: String] = [:]

    // MARK: - Init

    private init() {
        reload()
    }

    // MARK: - Paths

    /// Repo root: honour PULSAR_REPO_ROOT env var first, then default to
    /// ~/code/pulsar. This locates BUNDLED CODE ASSETS (e.g. the drone
    /// portrait frames under assets/portraits) — NOT mutable app state. Mutable
    /// state (config.json, cache/) lives under `storageRoot` in Application
    /// Support so the app works for DMG users with no checkout. Keep this here
    /// only for read-only asset lookups relative to the source tree.
    var repoRoot: URL {
        if let env = ProcessInfo.processInfo.environment["PULSAR_REPO_ROOT"],
           !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("code/pulsar")
    }

    /// Mutable app-state root. Defaults to a per-user Application Support dir
    /// (`~/Library/Application Support/Pulsar/`) so state lives OUTSIDE the code
    /// checkout — the app runs identically for DMG users with no source tree.
    /// Dev override: set `PULSAR_STORAGE` to point storage at a checkout's
    /// `cache/`+`config.json` instead.
    ///
    /// Directory is created on first access (best-effort).
    var storageRoot: URL {
        // Dev override wins.
        if let env = ProcessInfo.processInfo.environment["PULSAR_STORAGE"],
           !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Pulsar", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    var configPath: URL {
        storageRoot.appendingPathComponent("config.json")
    }

    var cacheDir: URL {
        storageRoot.appendingPathComponent("cache")
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
        let val = lock.withLock { _config["PULSAR_MUTED"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    /// Whether Potty Mouth mode is on. Default OFF (Polite). When ON, canon
    /// picks from the potty pool and bespoke /speak lines are delivered as-is
    /// (no scrubbing). When OFF, bespoke lines are scrubbed clean before being
    /// cached or spoken, making Polite authoritative regardless of caller text.
    var expletivesEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_EXPLETIVES"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    /// The user's chosen local (free-mode) voice. Empty = auto (Daniel Enhanced
    /// when installed, else basic Daniel). Set via the Settings voice picker.
    var nativeVoiceChoice: String {
        (lock.withLock { _config["PULSAR_NATIVE_VOICE"] }
            ?? ProcessInfo.processInfo.environment["PULSAR_NATIVE_VOICE"]
            ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Whether the cached "canon" fallback is allowed — the Stop hook's
    /// turn-end floor for turns the model didn't compose a bespoke line on.
    /// Off = bespoke-only: only the model's freshly composed lines speak (the
    /// default register). Speech is free (local `say`), so this is a style
    /// choice, not a cost lever. Default on preserves today's behaviour.
    var canonEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_CANON_ENABLED"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    /// Whether the animated floating Pulsar head is shown on screen while it
    /// speaks. Default ON preserves today's behaviour. When OFF, the floating
    /// window is never created/shown (the voice still plays).
    var floatingHeadEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_FLOATING_HEAD"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    /// Whether the read-along caption bubble is shown below the floating head
    /// while it speaks. Default ON. Gated by `floatingHeadEnabled` at the view
    /// layer — head off means no bubble regardless of this flag.
    var subtitlesEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_SUBTITLES"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    /// Whether the orbiting/clustered sub-agent "drones" (the active-agent swarm)
    /// are shown. Default ON. When OFF only Pulsar himself appears; the drones'
    /// voices still play but no drone heads are rendered.
    var showActiveAgents: Bool {
        let val = lock.withLock { _config["PULSAR_SHOW_AGENTS"] } ?? "1"
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
