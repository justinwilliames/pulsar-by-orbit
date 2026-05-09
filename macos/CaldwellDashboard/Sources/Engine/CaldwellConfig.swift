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
    static let defaultModel = "eleven_v3"
    static let defaultFormat = "mp3_44100_128"

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

    // MARK: - Config values

    var apiKey: String {
        // Keychain takes priority (parity with Python daemon's _api_key()).
        if let key = readKeychain(), !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? ""
    }

    var voiceId: String {
        lock.withLock { _config["ELEVENLABS_VOICE_ID"] }
            ?? ProcessInfo.processInfo.environment["ELEVENLABS_VOICE_ID"]
            ?? ""
    }

    var isMuted: Bool {
        let val = lock.withLock { _config["CALDWELL_MUTED"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    var expletivesEnabled: Bool {
        let val = lock.withLock { _config["CALDWELL_EXPLETIVES"] } ?? "1"
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        lock.withLock { _config = json }
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
