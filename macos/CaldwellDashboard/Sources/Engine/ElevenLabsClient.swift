import Foundation

/// Thin async wrapper around the ElevenLabs text-to-speech REST API.
/// Mirrors the Python daemon's _fetch_tts() — same model, same voice
/// settings, same output format (mp3_44100_128).
///
/// All methods are static and nonisolated; callers stay off the main thread.
enum ElevenLabsClient {

    enum Error: LocalizedError, Sendable {
        case noApiKey
        case noVoiceId
        case httpError(Int, String)
        case invalidAudio(String)

        var errorDescription: String? {
            switch self {
            case .noApiKey:
                return "ElevenLabs API key not set"
            case .noVoiceId:
                return "No voice ID configured"
            case .httpError(let code, let body):
                return "ElevenLabs HTTP \(code): \(body)"
            case .invalidAudio(let detail):
                return "Invalid MP3 received: \(detail)"
            }
        }
    }

    // MARK: - Public

    /// Per-attempt request timeout. Without this, URLSession's default 60s
    /// can pile up (60 × (retries+1) = 3 min worst-case) and stall the queue
    /// worker upstream. 20s is plenty for a small TTS call.
    static let perAttemptTimeoutSeconds: TimeInterval = 20

    /// Shared session with a sane request timeout. URLSession.shared defaults
    /// to 60s; replacing the timeout on a per-request `URLRequest` works too,
    /// but a dedicated session keeps the cap explicit.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = perAttemptTimeoutSeconds
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// Fetch TTS audio for `text` and write it to a temp file.
    /// Returns the URL of the temp MP3; caller is responsible for deletion.
    /// Retries up to `retries` times on 5xx errors (mirrors Python daemon).
    static func fetchTTS(
        text: String,
        voiceId: String,
        apiKey: String,
        retries: Int = 2
    ) async throws -> URL {
        guard !apiKey.isEmpty else { throw Error.noApiKey }
        guard !voiceId.isEmpty else { throw Error.noVoiceId }

        let cfg = CaldwellConfig.shared
        guard let url = URL(string:
            "\(CaldwellConfig.apiBase)/text-to-speech/\(voiceId)"
            + "?output_format=\(CaldwellConfig.defaultFormat)"
        ) else { throw Error.noVoiceId }

        let body: [String: Any] = [
            "text": text,
            "model_id": CaldwellConfig.defaultModel,
            "voice_settings": [
                "stability": cfg.voiceStability,
                "similarity_boost": cfg.voiceSimilarityBoost,
                "style": cfg.voiceStyle,
                "use_speaker_boost": cfg.voiceSpeakerBoost,
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var lastError: Swift.Error = Error.noApiKey
        for attempt in 0...retries {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload

            do {
                let (data, response) = try await session.data(for: req)
                // URLSession always returns HTTPURLResponse for http/https.
                let http = response as! HTTPURLResponse

                if http.statusCode != 200 {
                    let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
                    let err = Error.httpError(http.statusCode, snippet)
                    NSLog("[ElevenLabs] attempt \(attempt+1) HTTP \(http.statusCode): \(snippet.prefix(80))")
                    if attempt < retries && http.statusCode >= 500 {
                        lastError = err; continue
                    }
                    throw err
                }

                guard isValidMP3(data) else {
                    let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
                    let detail = "Content-Type=\(ct), \(data.count) bytes"
                    NSLog("[ElevenLabs] attempt \(attempt+1) invalid MP3: \(detail)")
                    let err = Error.invalidAudio(detail)
                    if attempt < retries { lastError = err; continue }
                    throw err
                }

                // Write to a temp file. Caller owns the lifecycle (deletes after use).
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("caldwell-tts-\(UUID().uuidString).mp3")
                try data.write(to: tmp)
                // Record the exact spend locally — this is the single chokepoint
                // for every ElevenLabs character we consume. /usage reconciles
                // this against ElevenLabs' laggy counter (see UsageTracker).
                UsageTracker.shared.recordCharacters(text.count)
                NSLog("[ElevenLabs] ✓ \(data.count) bytes → '\(text.prefix(50))'")
                return tmp

            } catch let err as Error {
                throw err   // Our own errors propagate immediately.
            } catch {
                NSLog("[ElevenLabs] attempt \(attempt+1) network error: \(error)")
                lastError = error
                if attempt < retries { continue }
                throw error
            }
        }
        throw lastError
    }

    // MARK: - Helpers

    /// Rudimentary MP3 validity check — mirrors Python daemon's _validate_mp3().
    private static func isValidMP3(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        if data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 { return true }  // ID3
        if data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 { return true }             // MPEG sync
        return false
    }
}
