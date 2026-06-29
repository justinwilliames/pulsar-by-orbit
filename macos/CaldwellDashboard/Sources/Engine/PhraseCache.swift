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
/// Eviction: LRU by last-played-at. Phrases that have never been played
/// sort to the tail and are evicted first. Cap is 50 MB.
///
/// Thread-safety: all public methods are synchronous and blocking.
/// Callers should run them on a background thread / actor.
final class PhraseCache: @unchecked Sendable {
    static let shared = PhraseCache()
    private init() {}

    let maxBytes = 50 * 1024 * 1024   // 50 MB

    var phraseCacheDir: URL {
        CaldwellConfig.shared.phraseCacheDir
    }

    // MARK: - Key

    // Frozen ElevenLabs synthesis parameters the canon phrase cache was warmed
    // under by warm-cache.sh. ElevenLabs is gone, but cached MP3s on disk are
    // still keyed by this exact formula — the bytes must stay identical to the
    // Python _phrase_cache_key() that produced them, or every lookup misses.
    private static let canonModel = "eleven_multilingual_v2"
    private static let canonStability = 0.35
    private static let canonSimilarityBoost = 0.75
    private static let canonStyle = 0.50
    private static let canonSpeakerBoost = true

    /// Derive the 32-char cache key for (text, voiceId).
    /// Must produce the same bytes as Python's _phrase_cache_key().
    func key(text: String, voiceId: String) -> String {
        let textJSON = jsonStringLiteral(text)
        let voiceJSON = jsonStringLiteral(voiceId)
        let stability = formatDouble(Self.canonStability)
        let simBoost = formatDouble(Self.canonSimilarityBoost)
        let style = formatDouble(Self.canonStyle)
        let speakerBoost = Self.canonSpeakerBoost ? "true" : "false"
        let model = Self.canonModel

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
    /// Updates last_played_at and play_count in the sidecar on every hit.
    func get(text: String, voiceId: String) -> URL? {
        let k = key(text: text, voiceId: voiceId)
        let mp3 = phraseCacheDir.appendingPathComponent("\(k).mp3")
        guard FileManager.default.fileExists(atPath: mp3.path) else { return nil }

        // Update sidecar metadata so LRU order stays accurate.
        updateSidecarOnPlay(key: k)
        return mp3
    }

    // MARK: - Write

    /// Copy the audio at `sourceURL` into the phrase cache, then evict if needed.
    func put(text: String, voiceId: String, sourceURL: URL) throws {
        let dir = phraseCacheDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let k = key(text: text, voiceId: voiceId)
        let dest = dir.appendingPathComponent("\(k).mp3")

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        // Write sidecar.
        let now = Date().timeIntervalSince1970
        let meta: [String: Any] = [
            "key": k,
            "text": text,
            "voice_id": voiceId,
            "voice_label": "Caldwell",
            "created_at": now,
            "first_cached_at": now,
            "last_played_at": now,
            "char_count": text.count,
            "play_count": 1,
        ]
        let sidecar = dir.appendingPathComponent("\(k).json")
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: sidecar)

        NSLog("[PhraseCache] PUT key=\(k) text=\(text.prefix(40))")
        evict()
    }

    // MARK: - Eviction

    /// Remove the least-recently-played entries until total MP3 bytes ≤ maxBytes.
    /// Never-played entries (last_played_at == 0) sort to the tail and go first.
    func evict() {
        let dir = phraseCacheDir
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }

        struct Entry {
            let key: String
            let mp3URL: URL
            let bytes: Int
            let lastPlayedAt: Double
        }

        var entries: [Entry] = []
        var totalBytes = 0

        for url in contents where url.pathExtension == "mp3" {
            let key = url.deletingPathExtension().lastPathComponent
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += bytes

            let sidecarURL = dir.appendingPathComponent("\(key).json")
            var lastPlayedAt = 0.0
            if let data = try? Data(contentsOf: sidecarURL),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                lastPlayedAt = meta["last_played_at"] as? Double
                    ?? meta["created_at"] as? Double
                    ?? 0
            }
            entries.append(Entry(key: key, mp3URL: url, bytes: bytes, lastPlayedAt: lastPlayedAt))
        }

        guard totalBytes > maxBytes else { return }

        // Most recently played first → least recently played at tail → evict tail.
        entries.sort { $0.lastPlayedAt > $1.lastPlayedAt }

        var remaining = totalBytes
        for entry in entries.reversed() {
            guard remaining > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.mp3URL)
            let sidecarURL = dir.appendingPathComponent("\(entry.key).json")
            try? FileManager.default.removeItem(at: sidecarURL)
            remaining -= entry.bytes
            NSLog("[PhraseCache] EVICT key=\(entry.key) freed=\(entry.bytes)b")
        }
    }

    // MARK: - Sidecar update

    private func updateSidecarOnPlay(key: String) {
        let sidecarURL = phraseCacheDir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: sidecarURL),
              var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        meta["last_played_at"] = Date().timeIntervalSince1970
        meta["play_count"] = (meta["play_count"] as? Int ?? 0) + 1

        if let updated = try? JSONSerialization.data(withJSONObject: meta) {
            try? updated.write(to: sidecarURL)
        }
    }

    // MARK: - Helpers

    private func jsonStringLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return str
    }

    private func formatDouble(_ d: Double) -> String {
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(d))
        }
        return String(format: "%g", d)
    }
}
