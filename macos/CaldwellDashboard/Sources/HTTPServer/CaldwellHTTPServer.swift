import Foundation
import Hummingbird

/// Local HTTP server hosted inside Caldwell.app. Exposes the same REST surface
/// as the Python daemon so `say.sh`, the Stop hook, and external scripts keep
/// working unchanged once the daemon is retired.
///
/// Port schedule:
///   7866 — migration port (coexists with Python daemon on 7865)
///   7865 — Phase 5: daemon retired, this becomes the sole listener
///
/// Phase progress:
///   Phase 1 ✓  /health
///   Phase 2 ✓  /speak  (ElevenLabs TTS, phrase cache, audio queue)
///   Phase 3    /history, /cache/*, /settings, /usage
///   Phase 4    /events (SSE), /portraits/*
///   Phase 5    flip to 7865, retire Python daemon
final class CaldwellHTTPServer: @unchecked Sendable {

    static let migrationPort: Int = 7866

    private var serverTask: Task<Void, Error>?
    private let port: Int
    let audioQueue = AudioQueueActor()

    init(port: Int = CaldwellHTTPServer.migrationPort) {
        self.port = port
    }

    func start() {
        guard serverTask == nil else {
            NSLog("[CaldwellHTTP] start() called while already running — ignoring")
            return
        }

        let port = self.port
        let audioQueue = self.audioQueue

        serverTask = Task.detached(priority: .userInitiated) {
            do {
                let router = Router()
                Self.registerRoutes(on: router, audioQueue: audioQueue)

                let app = Application(
                    router: router,
                    configuration: .init(
                        address: .hostname("127.0.0.1", port: port),
                        serverName: "caldwell-http"
                    )
                )

                NSLog("[CaldwellHTTP] starting on 127.0.0.1:\(port)")
                try await app.runService()
            } catch {
                NSLog("[CaldwellHTTP] server crashed: \(error)")
            }
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
    }

    // MARK: - Routes

    nonisolated private static func registerRoutes(
        on router: Router<BasicRequestContext>,
        audioQueue: AudioQueueActor
    ) {
        // GET /health — parity with Python daemon
        router.get("/health") { _, _ -> Response in
            return try Self.json(HealthResponse(
                status: "ok",
                version: "swift-2.0",
                queue_size: 0,
                source: "swift"
            ))
        }

        // POST /speak — TTS enqueue with phrase-cache support
        router.post("/speak") { request, _ -> Response in
            return try await Self.handleSpeak(request: request, audioQueue: audioQueue)
        }
    }

    // MARK: - /speak handler

    nonisolated private static func handleSpeak(
        request: Request,
        audioQueue: AudioQueueActor
    ) async throws -> Response {

        // Parse body
        guard let bodyData = try? await request.body.collect(upTo: 1024 * 1024) else {
            return try Self.json(ErrorResponse("Invalid request body"), status: .badRequest)
        }
        guard let body = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any] else {
            return try Self.json(ErrorResponse("Invalid JSON"), status: .badRequest)
        }

        // Validate text
        guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return try Self.json(ErrorResponse("No text provided"), status: .badRequest)
        }
        let maxLen = 5000
        guard text.count <= maxLen else {
            return try Self.json(ErrorResponse("Text too long (max \(maxLen) chars)"), status: .badRequest)
        }

        // Hard mute — return 200 with muted flag; caller won't retry
        let cfg = CaldwellConfig.shared
        if cfg.isMuted {
            return try Self.json(MutedResponse(muted: true, text_preview: String(text.prefix(100))))
        }

        let voiceRaw = body["voice"] as? String
        let cacheable  = body["cacheable"]  as? Bool ?? false
        let cacheOnly  = body["cache_only"] as? Bool ?? false
        let channel    = body["channel"]    as? String
        let priority   = body["priority"]   as? Bool ?? false

        // Resolve voice ID — needed for cache key.
        let voiceId = voiceRaw ?? cfg.voiceId

        // Phrase cache check.
        // Cached phrases play from disk — no API key, no quota, no ElevenLabs call.
        // This runs BEFORE credential validation so cached lines always succeed.
        let cachedURL = voiceId.isEmpty ? nil : PhraseCache.shared.get(text: text, voiceId: voiceId)

        // cache_only + hit → return immediately, nothing enqueued
        if cacheOnly, let url = cachedURL {
            let key = PhraseCache.shared.key(text: text, voiceId: voiceId)
            return try Self.json(CacheOnlyResponse(cached: true, fresh: false, key: key, char_count: text.count))
        }

        // cache_only + miss → fetch, cache, return (no playback)
        if cacheOnly {
            guard !cfg.apiKey.isEmpty else {
                return try Self.json(ErrorResponse("ELEVENLABS_API_KEY not set"), status: .internalServerError)
            }
            guard !voiceId.isEmpty else {
                return try Self.json(ErrorResponse("No voice specified and ELEVENLABS_VOICE_ID not set"), status: .badRequest)
            }
            do {
                let tmp = try await ElevenLabsClient.fetchTTS(text: text, voiceId: voiceId, apiKey: cfg.apiKey)
                try PhraseCache.shared.put(text: text, voiceId: voiceId, sourceURL: tmp)
                try? FileManager.default.removeItem(at: tmp)
                let key = PhraseCache.shared.key(text: text, voiceId: voiceId)
                return try Self.json(CacheOnlyResponse(cached: true, fresh: true, key: key, char_count: text.count))
            } catch {
                return try Self.json(ErrorResponse(error.localizedDescription), status: .internalServerError)
            }
        }

        // Normal flow — validate credentials only on a cache miss
        if cachedURL == nil {
            guard !cfg.apiKey.isEmpty else {
                return try Self.json(ErrorResponse("ELEVENLABS_API_KEY not set"), status: .internalServerError)
            }
            guard !voiceId.isEmpty else {
                return try Self.json(ErrorResponse("No voice specified and ELEVENLABS_VOICE_ID not set"), status: .badRequest)
            }
        }

        // Build the entry and enqueue.
        let entryId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        var entry = AudioEntry(
            id: String(entryId),
            text: String(text.prefix(100)),
            voiceId: voiceId,
            voiceLabel: voiceId,   // Phase 3 will resolve display names
            createdAt: Date(),
            channel: channel,
            priority: priority,
            fullText: text,
            isReplay: false,
            audioURL: cachedURL   // non-nil = cache hit, nil = fetch pending
        )

        // Cache hit: copy to temp so the queue worker can delete without
        // nuking the phrase-cache file (mirrors Python daemon behaviour).
        if let cached = cachedURL {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("caldwell-tts-\(entryId).mp3")
            if (try? FileManager.default.copyItem(at: cached, to: tmp)) != nil {
                entry.audioURL = tmp
            }
        }

        let position = await audioQueue.enqueue(entry)

        // Cache miss: fetch in background, signal the worker when ready.
        if cachedURL == nil {
            let entryIdCopy = String(entryId)
            let textCopy = text
            let voiceIdCopy = voiceId
            let apiKey = cfg.apiKey
            Task.detached {
                do {
                    let url = try await ElevenLabsClient.fetchTTS(
                        text: textCopy, voiceId: voiceIdCopy, apiKey: apiKey
                    )
                    if cacheable {
                        try? PhraseCache.shared.put(text: textCopy, voiceId: voiceIdCopy, sourceURL: url)
                    }
                    await audioQueue.markReady(id: entryIdCopy, url: url)
                } catch {
                    NSLog("[CaldwellHTTP] Background TTS fetch failed for \(entryIdCopy): \(error)")
                    await audioQueue.markFailed(id: entryIdCopy)
                }
            }
        }

        return try Self.json(SpeakResponse(
            id: String(entryId),
            position: position,
            voice: voiceId,
            text_preview: String(text.prefix(100))
        ))
    }

    // MARK: - JSON helper

    nonisolated private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    nonisolated private static func json<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status = .ok
    ) throws -> Response {
        let data = try encoder.encode(value)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}

// MARK: - Response models

private struct HealthResponse: Encodable, Sendable {
    let status: String
    let version: String
    let queue_size: Int
    let source: String
}

private struct ErrorResponse: Encodable, Sendable {
    let error: String
    init(_ message: String) { self.error = message }
}

private struct MutedResponse: Encodable, Sendable {
    let muted: Bool
    let text_preview: String
}

private struct SpeakResponse: Encodable, Sendable {
    let id: String
    let position: Int
    let voice: String
    let text_preview: String
}

private struct CacheOnlyResponse: Encodable, Sendable {
    let cached: Bool
    let fresh: Bool
    let key: String
    let char_count: Int
}
