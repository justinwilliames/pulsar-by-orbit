import Foundation
import CryptoKit

/// Content-addressed on-disk cache for ElevenLabs MP3 audio.
///
/// Cache key format is byte-for-byte compatible with the Python daemon's
/// _phrase_cache_key() — so phrases warmed by warm-cache.sh (which hits the
/// Python daemon) are immediately reusable by the Swift server, and vice versa.
///
/// Key derivation (mirrors server.py):
///   SHA256( json.dumps({...}, sort_keys=True) )[:32]
/// where the JSON uses Python's default separators (", " and ": ").
///
/// Thread-safe via NSLock. All methods are synchronous and blocking — callers
/// should run them on a background thread (Task.detached / actor isolation).
final class PhraseCache: @unchecked Sendable {
    static let shared = PhraseCache()
    private init() {}

    let maxBytes = 100 * 1024 * 1024

    var phraseCacheDir: URL {
        CaldwellConfig.shared.phraseCacheDir
    }

    // MARK: - Key

    /// Derive the 32-char cache key for (text, voiceId).
    /// Must produce the same bytes as Python's _phrase_cache_key().
    func key(text: String, voiceId: String) -> String {
        let cfg = CaldwellConfig.shared
        // Construct JSON manually to exactly match Python's json.dumps output:
        //   {"model": "...", "text": "...", "voice_id": "...", "voice_settings": {...}}
        // Keys are sorted alphabetically (sort_keys=True); separators are ", " and ": ".
        let textJSON = jsonStringLiteral(text)
        let voiceJSON = jsonStringLiteral(voiceId)
        let stability = formatDouble(cfg.voiceStability)
        let simBoost = formatDouble(cfg.voiceSimilarityBoost)
        let style = formatDouble(cfg.voiceStyle)
        let speakerBoost = cfg.voiceSpeakerBoost ? "true" : "false"
        let model = CaldwellConfig.defaultModel

        // Outer keys sorted: model, text, voice_id, voice_settings
        // Inner voice_settings keys sorted: similarity_boost, stability, style, use_speaker_boost
        let json = """
        {"model": "\(model)", "text": \(textJSON), "voice_id": \(voiceJSON), \
        "voice_settings": {"similarity_boost": \(simBoost), "stability": \(stability), \
        "style": \(style), "use_speaker_boost": \(speakerBoost)}}
        """

        let hash = SHA256.hash(data: Data(json.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    // MARK: - Read

    /// Returns the URL of the cached MP3 if it exists, nil on a miss.
    /// Touches the file's atime (for LRU pruning parity with Python).
    func get(text: String, voiceId: String) -> URL? {
        let k = key(text: text, voiceId: voiceId)
        let mp3 = phraseDir().appendingPathComponent("\(k).mp3")
        guard FileManager.default.fileExists(atPath: mp3.path) else { return nil }
        // Touch atime — best-effort, ignore failure.
        _ = try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: mp3.path
        )
        return mp3
    }

    // MARK: - Write

    /// Copy the audio at `sourcePath` into the phrase cache.
    /// Creates the cache directory if needed.
    func put(text: String, voiceId: String, sourceURL: URL) throws {
        let dir = phraseDir()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let k = key(text: text, voiceId: voiceId)
        let dest = dir.appendingPathComponent("\(k).mp3")
        // Overwrite any stale entry.
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        // Write JSON sidecar (mirrors Python's _phrase_cache_save_meta).
        let meta: [String: Any] = [
            "key": k,
            "text": text,
            "voice_id": voiceId,
            "voice_label": voiceId, // Phase 3 will resolve labels properly
            "created_at": Date().timeIntervalSince1970,
            "char_count": text.count,
            "play_count": 0,
        ]
        let sidecar = dir.appendingPathComponent("\(k).json")
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: sidecar)
        NSLog("[PhraseCache] PUT key=\(k) text=\(text.prefix(40))")
    }

    // MARK: - Helpers

    private func phraseDir() -> URL {
        phraseCacheDir
    }

    /// Produce a JSON string literal (with surrounding quotes) that matches
    /// Python's json.dumps for a string value — handles the common characters
    /// that need escaping. We use JSONEncoder for correctness.
    private func jsonStringLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return str
    }

    /// Format a Double the way Python's json.dumps does:
    /// - Integers print without trailing ".0" → "1" not "1.0"
    /// - "Normal" floats print the minimal decimal repr → "0.75" not "0.75000..."
    private func formatDouble(_ d: Double) -> String {
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(d))
        }
        // Use %g which strips trailing zeros and matches Python's float repr.
        let s = String(format: "%g", d)
        return s
    }
}
