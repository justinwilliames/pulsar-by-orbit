import Foundation
import Security

/// Singleton config store. Reads from:
///   1. macOS Keychain — ElevenLabs API key (service: "caldwell-speak",
///      account: "elevenlabs-api-key") — shared with the Python daemon.
///   2. REPO_ROOT/config.json — voice_id, muted state, expletives toggle.
///   3. Environment variables — fallback for API key + overrides for voice
///      settings (SPEAK_VOICE_STABILITY etc) so say.sh env-var overrides work.
///
/// Thread-safe: all mutations go through an NSLock. Call `reload()` after
/// writing config.json to pick up new values without restarting the app.
final class CaldwellConfig: @unchecked Sendable {
    static let shared = CaldwellConfig()

    // MARK: - Constants matching daemon/server.py defaults

    static let apiBase = "https://api.elevenlabs.io/v1"
    // eleven_v3 is gated to paid tiers and returns HTTP 402 on free plans.
    // eleven_multilingual_v2 works on free, supports custom voices, decent
    // quality. Upgrade to v3 when Sir moves off the free tier.
    static let defaultModel = "eleven_multilingual_v2"
    static let defaultFormat = "mp3_44100_128"

    /// Stock ElevenLabs "George" — British, mature. Works on every tier
    /// including free, ships warm-cache canon under this voice, and is
    /// the closest premade to Caldwell's intended register. Used as the
    /// fallback when no voice has been chosen yet.
    static let defaultVoiceId = "JBFqnCBsd6RMkjVDRZzb"

    /// Keychain coordinates — must match the Python daemon's.
    private let keychainService = "caldwell-speak"
    private let keychainAccountApiKey = "elevenlabs-api-key"

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

    var apiKey: String {
        // Keychain takes priority (parity with Python daemon's _api_key()).
        if let key = readKeychain(), !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? ""
    }

    // Cached "is a key present?" so /settings never blocks on the Keychain in the
    // async handler path — a synchronous SecItemCopyMatching under concurrent
    // polls starves the cooperative pool and wedges the server. Primed lazily in
    // the background; refreshed on setApiKey.
    nonisolated(unsafe) private static var cachedApiKeyPresent: Bool?
    private static let apiKeyPresenceLock = NSLock()

    /// Non-blocking key-presence check for hot paths (/settings). Reads cache; if
    /// unprimed, kicks a background prime and answers from the env var for now.
    func apiKeyIsSet() -> Bool {
        if let c = (Self.apiKeyPresenceLock.withLock { Self.cachedApiKeyPresent }) { return c }
        Task.detached { _ = CaldwellConfig.shared.refreshApiKeyPresence() }
        return !(ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? "").isEmpty
    }

    /// Recompute presence from the Keychain (blocking) and cache it. Background only.
    @discardableResult
    func refreshApiKeyPresence() -> Bool {
        let present = !apiKey.isEmpty
        Self.apiKeyPresenceLock.withLock { Self.cachedApiKeyPresent = present }
        return present
    }

    var voiceId: String {
        let stored = lock.withLock { _config["ELEVENLABS_VOICE_ID"] }
            ?? ProcessInfo.processInfo.environment["ELEVENLABS_VOICE_ID"]
            ?? ""
        // Fresh-install fallback: when no voice has been configured yet,
        // use the bundled free-tier-safe default so the very first call
        // works without Sir having to open Settings.
        return stored.isEmpty ? Self.defaultVoiceId : stored
    }

    var isMuted: Bool {
        let val = lock.withLock { _config["CALDWELL_MUTED"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    var expletivesEnabled: Bool {
        let val = lock.withLock { _config["CALDWELL_EXPLETIVES"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    /// Which engine speaks: "elevenlabs" (premium cloud) or "native" (free local
    /// macOS voice). Default "elevenlabs" preserves today's behaviour.
    var voiceEngine: String {
        let val = (lock.withLock { _config["CALDWELL_VOICE_ENGINE"] }
            ?? ProcessInfo.processInfo.environment["CALDWELL_VOICE_ENGINE"]
            ?? "elevenlabs").lowercased()
        return val == "native" ? "native" : "elevenlabs"
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

    // MARK: - Voice settings (mirrors SPEAK_VOICE_* env vars in server.py)

    var voiceStability: Double {
        env("SPEAK_VOICE_STABILITY", default: 0.35)
    }
    var voiceSimilarityBoost: Double {
        env("SPEAK_VOICE_SIMILARITY_BOOST", default: 0.75)
    }
    var voiceStyle: Double {
        env("SPEAK_VOICE_STYLE", default: 0.50)
    }
    var voiceSpeakerBoost: Bool {
        let val = ProcessInfo.processInfo.environment["SPEAK_VOICE_SPEAKER_BOOST"] ?? "1"
        return !["0", "false", "no", ""].contains(val.lowercased())
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

    /// Persist the ElevenLabs API key in macOS Keychain.
    func setApiKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccountApiKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let attributes: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery.removeValue(forKey: kSecReturnData)
            addQuery.removeValue(forKey: kSecMatchLimit)
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        Self.apiKeyPresenceLock.withLock { Self.cachedApiKeyPresent = true }
    }

    // MARK: - Keychain

    private func readKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccountApiKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    // MARK: - Helpers

    private func env(_ name: String, default d: Double) -> Double {
        guard let s = ProcessInfo.processInfo.environment[name],
              let v = Double(s) else { return d }
        return v
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
