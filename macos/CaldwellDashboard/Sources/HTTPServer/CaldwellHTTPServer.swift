import Foundation
import Hummingbird

/// Local HTTP server hosted inside Caldwell.app. Exposes the same REST surface
/// as the Python daemon so `say.sh`, the Stop hook, and external scripts keep
/// working unchanged now that the daemon is retired.
///
/// Port:
///   7865 — Phase 5: now the sole listener on 7865, Python daemon retired
///
/// Phase progress:
///   Phase 1 ✓  /health
///   Phase 2 ✓  /speak  (ElevenLabs TTS, phrase cache, audio queue)
///   Phase 3    /history, /cache/*, /settings, /usage
///   Phase 4    /events (SSE), /portraits/*
///   Phase 5 ✓  flip to 7865, retire Python daemon
final class CaldwellHTTPServer: @unchecked Sendable {

    static let migrationPort: Int = 7865

    private var serverTask: Task<Void, Error>?
    private let port: Int
    let audioQueue = AudioQueueActor()
    let sseBroadcaster = SSEBroadcaster()

    init(port: Int = CaldwellHTTPServer.migrationPort) {
        self.port = port
    }

    func configure() async {
        await audioQueue.setBroadcaster(sseBroadcaster)
    }

    func start() {
        guard serverTask == nil else {
            NSLog("[CaldwellHTTP] start() called while already running — ignoring")
            return
        }

        let port = self.port
        let audioQueue = self.audioQueue
        let sseBroadcaster = self.sseBroadcaster

        serverTask = Task.detached(priority: .userInitiated) {
            do {
                let router = Router()
                Self.registerRoutes(
                    on: router,
                    audioQueue: audioQueue,
                    sseBroadcaster: sseBroadcaster
                )

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
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster
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

        // GET /history — recent playback history
        router.get("/history") { request, _ -> Response in
            return try await Self.handleHistory(request: request, audioQueue: audioQueue)
        }

        // GET /events — server-sent events stream
        router.get("/events") { _, _ -> Response in
            return try await Self.handleEvents(audioQueue: audioQueue, sseBroadcaster: sseBroadcaster)
        }

        // GET /cache/phrases — cached phrase metadata
        router.get("/cache/phrases") { request, _ -> Response in
            return try Self.handleCachePhrases(request: request)
        }

        // DELETE /cache/phrases/:key — remove one cached phrase
        router.delete("/cache/phrases/:key") { _, context -> Response in
            return try Self.handleCacheDelete(context: context)
        }

        // POST /cache/clear — wipe the phrase cache
        router.post("/cache/clear") { _, _ -> Response in
            return try Self.handleCacheClear()
        }

        // POST /cache/play/:key — enqueue a cached phrase by key
        router.post("/cache/play/:key") { _, context -> Response in
            return try await Self.handleCachePlay(context: context, audioQueue: audioQueue)
        }

        // Compatibility with the legacy daemon client, which POSTs {"key": "..."}.
        router.post("/cache/play") { request, _ -> Response in
            return try await Self.handleCachePlayCompat(request: request, audioQueue: audioQueue)
        }

        // GET /settings — current non-secret config
        router.get("/settings") { _, _ -> Response in
            return try Self.handleSettingsGet()
        }

        // POST /settings — update config + Keychain API key
        router.post("/settings") { request, _ -> Response in
            return try await Self.handleSettingsPost(request: request)
        }

        // GET /usage — ElevenLabs subscription usage
        router.get("/usage") { _, _ -> Response in
            return try await Self.handleUsage()
        }

        // GET /portraits/:name/:frame — serve portrait assets to the app UI
        router.get("/portraits/:name/:frame") { _, context -> Response in
            return try Self.handlePortrait(context: context)
        }

        // POST /canon/pick — play a context-appropriate cached canon line.
        // Cache-only — never spends ElevenLabs credit. Returns 204 if no
        // cached canon matches the requested context.
        router.post("/canon/pick") { request, _ -> Response in
            return try await Self.handleCanonPick(request: request, audioQueue: audioQueue)
        }

        // GET /queue — current queue snapshot. Hook uses this to detect
        // in-flight plays before deciding whether to fire its own ping.
        router.get("/queue") { request, _ -> Response in
            return try await Self.handleQueue(request: request, audioQueue: audioQueue)
        }
    }

    // MARK: - /queue handler

    nonisolated private static func handleQueue(
        request: Request,
        audioQueue: AudioQueueActor
    ) async throws -> Response {
        let limit = max(1, min(request.uri.queryParameters.get("limit", as: Int.self) ?? 20, 100))
        let channel = request.uri.queryParameters.get("channel")
        let snapshot = await audioQueue.statusSnapshot(limit: limit, channel: channel)
        return try Self.json(snapshot)
    }

    // MARK: - /history handler

    nonisolated private static func handleHistory(
        request: Request,
        audioQueue: AudioQueueActor
    ) async throws -> Response {
        let limit = max(1, min(request.uri.queryParameters.get("limit", as: Int.self) ?? 50, 200))
        let offset = max(0, request.uri.queryParameters.get("offset", as: Int.self) ?? 0)
        let channel = request.uri.queryParameters.get("channel")

        let items = await audioQueue.historyItems(limit: limit, offset: offset, channel: channel)
            .map(HistoryResponseItem.init)
        return try Self.json(items)
    }

    // MARK: - /events handler

    nonisolated private static func handleEvents(
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster
    ) async throws -> Response {
        let state = await audioQueue.statusSnapshot(limit: 20)
        let stateJSON = try Self.jsonString(state)
        let clientStream = await sseBroadcaster.makeStream()

        let bodyStream = AsyncStream<ByteBuffer> { continuation in
            let task = Task {
                continuation.yield(ByteBuffer(string: Self.ssePayload(event: "connected", json: "{}")))
                continuation.yield(ByteBuffer(string: Self.ssePayload(event: "state", json: stateJSON)))

                for await payload in clientStream {
                    if Task.isCancelled {
                        break
                    }
                    continuation.yield(ByteBuffer(string: payload))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        headers[.connection] = "keep-alive"

        return Response(
            status: .ok,
            headers: headers,
            body: ResponseBody(asyncSequence: bodyStream)
        )
    }

    // MARK: - /portraits handler

    nonisolated private static func handlePortrait(
        context: BasicRequestContext
    ) throws -> Response {
        let name = try context.parameters.require("name")
        let frame = try context.parameters.require("frame")

        let portraitsRoot = CaldwellConfig.shared.repoRoot
            .appendingPathComponent("assets/portraits", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let portraitURL = portraitsRoot
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(frame)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let legacyPortraitURL = portraitsRoot
            .appendingPathComponent(Self.legacyPortraitFilename(name: name, frame: frame))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = portraitsRoot.path.hasSuffix("/") ? portraitsRoot.path : portraitsRoot.path + "/"

        guard portraitURL.path.hasPrefix(rootPrefix), legacyPortraitURL.path.hasPrefix(rootPrefix) else {
            return try Self.json(ErrorResponse("not found"), status: .notFound)
        }

        let fileURL: URL
        if FileManager.default.fileExists(atPath: portraitURL.path) {
            fileURL = portraitURL
        } else if FileManager.default.fileExists(atPath: legacyPortraitURL.path) {
            fileURL = legacyPortraitURL
        } else {
            return try Self.json(ErrorResponse("not found"), status: .notFound)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var headers = HTTPFields()
            headers[.contentType] = Self.contentType(for: fileURL)
            return Response(
                status: .ok,
                headers: headers,
                body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
            )
        } catch {
            return try Self.json(ErrorResponse(error.localizedDescription), status: .internalServerError)
        }
    }

    // MARK: - /cache handlers

    nonisolated private static func handleCachePhrases(request: Request) throws -> Response {
        let dir = PhraseCache.shared.phraseCacheDir
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return try Self.json(CachePhrasesResponse(
                phrases: [],
                count: 0,
                total_bytes: 0,
                max_bytes: PhraseCache.shared.maxBytes
            ))
        }

        let limit = max(1, request.uri.queryParameters.get("limit", as: Int.self) ?? Int.max)
        let sort = request.uri.queryParameters.get("sort") ?? "recent"

        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var phrases: [CachedPhraseRecord] = []
        var totalBytes = 0

        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let meta = Self.loadPhraseSidecar(from: url) else { continue }
            totalBytes += Self.fileSize(at: dir.appendingPathComponent("\(meta.key).mp3"))
            phrases.append(meta.responseRecord)
        }

        switch sort {
        case "popular":
            phrases.sort { lhs, rhs in
                if lhs.play_count == rhs.play_count {
                    return lhs.created_at > rhs.created_at
                }
                return lhs.play_count > rhs.play_count
            }
        default:
            phrases.sort { $0.created_at > $1.created_at }
        }

        let limited = Array(phrases.prefix(limit))
        return try Self.json(CachePhrasesResponse(
            phrases: limited,
            count: limited.count,
            total_bytes: totalBytes,
            max_bytes: PhraseCache.shared.maxBytes
        ))
    }

    nonisolated private static func handleCacheDelete(
        context: BasicRequestContext
    ) throws -> Response {
        let key = try context.parameters.require("key")
        guard Self.isValidPhraseCacheKey(key) else {
            return try Self.json(ErrorResponse("invalid key"), status: .badRequest)
        }

        let dir = PhraseCache.shared.phraseCacheDir
        let audioURL = dir.appendingPathComponent("\(key).mp3")
        let sidecarURL = dir.appendingPathComponent("\(key).json")

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return try Self.json(ErrorResponse("not found"), status: .notFound)
        }

        do {
            try FileManager.default.removeItem(at: audioURL)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try? FileManager.default.removeItem(at: sidecarURL)
            }
            return try Self.json(DeletePhraseResponse(deleted: true))
        } catch {
            return try Self.json(ErrorResponse(error.localizedDescription), status: .internalServerError)
        }
    }

    nonisolated private static func handleCacheClear() throws -> Response {
        let dir = PhraseCache.shared.phraseCacheDir
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return try Self.json(ClearCacheResponse(cleared: true, count: 0))
        }

        var cleared = 0
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "mp3" || ext == "json" else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                if ext == "mp3" {
                    cleared += 1
                }
            } catch {
                continue
            }
        }

        return try Self.json(ClearCacheResponse(cleared: true, count: cleared))
    }

    nonisolated private static func handleCachePlay(
        context: BasicRequestContext,
        audioQueue: AudioQueueActor
    ) async throws -> Response {
        let key = try context.parameters.require("key")
        return try await Self.handleCachePlay(key: key, audioQueue: audioQueue)
    }

    nonisolated private static func handleCachePlayCompat(
        request: Request,
        audioQueue: AudioQueueActor
    ) async throws -> Response {
        let body: CachePlayBody
        do {
            body = try await Self.decodeBody(CachePlayBody.self, from: request)
        } catch {
            return try Self.json(ErrorResponse("Invalid JSON"), status: .badRequest)
        }
        return try await Self.handleCachePlay(key: body.key, audioQueue: audioQueue)
    }

    nonisolated private static func handleCachePlay(
        key: String,
        audioQueue: AudioQueueActor
    ) async throws -> Response {
        guard Self.isValidPhraseCacheKey(key) else {
            return try Self.json(ErrorResponse("invalid key"), status: .badRequest)
        }

        let dir = PhraseCache.shared.phraseCacheDir
        let audioURL = dir.appendingPathComponent("\(key).mp3")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return try Self.json(ErrorResponse("not found"), status: .notFound)
        }

        let sidecarURL = dir.appendingPathComponent("\(key).json")
        var meta = Self.loadPhraseSidecar(from: sidecarURL)
        if meta != nil {
            meta?.play_count += 1
            meta?.last_played_at = Date().timeIntervalSince1970
            try? Self.savePhraseSidecar(meta!, to: sidecarURL)
        }

        let entryId = Self.nextEntryId()
        let tmpURL: URL
        do {
            tmpURL = try Self.copyCacheAudioToTemp(sourceURL: audioURL, entryId: entryId)
        } catch {
            return try Self.json(ErrorResponse(error.localizedDescription), status: .internalServerError)
        }

        let entry = AudioEntry(
            id: entryId,
            text: String((meta?.text ?? "(cached phrase)").prefix(100)),
            voiceId: meta?.voice_id ?? "",
            voiceLabel: meta?.voice_label ?? meta?.voice_id ?? "Caldwell",
            createdAt: Date(),
            channel: nil,
            priority: false,
            fullText: meta?.text ?? "",
            isReplay: true,
            audioURL: tmpURL
        )

        let position = await audioQueue.enqueue(entry)
        if position == nil {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        return try Self.json(CachePlayResponse(
            id: entryId,
            position: position,
            dropped: position == nil ? true : nil
        ))
    }

    // MARK: - /settings handlers

    nonisolated private static func handleSettingsGet() throws -> Response {
        return try Self.json(Self.currentSettings())
    }

    nonisolated private static func handleSettingsPost(
        request: Request
    ) async throws -> Response {
        let update: SettingsUpdateRequest
        do {
            update = try await Self.decodeBody(SettingsUpdateRequest.self, from: request)
        } catch {
            return try Self.json(ErrorResponse("Invalid JSON"), status: .badRequest)
        }

        guard update.voice_id != nil ||
                update.muted != nil ||
                update.expletives_enabled != nil ||
                update.api_key != nil
        else {
            return try Self.json(ErrorResponse("No fields to update"), status: .badRequest)
        }

        let config = CaldwellConfig.shared

        do {
            if let apiKey = update.api_key {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return try Self.json(ErrorResponse("api_key must not be empty"), status: .badRequest)
                }
                try config.setApiKey(trimmed)
            }

            if let voiceId = update.voice_id {
                try config.set("ELEVENLABS_VOICE_ID", value: voiceId.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let muted = update.muted {
                try config.set("CALDWELL_MUTED", value: muted ? "1" : "0")
            }
            if let expletives = update.expletives_enabled {
                try config.set("CALDWELL_EXPLETIVES", value: expletives ? "1" : "0")
            }
        } catch {
            return try Self.json(ErrorResponse(error.localizedDescription), status: .internalServerError)
        }

        return try Self.json(Self.currentSettings())
    }

    // MARK: - /usage handler

    nonisolated private static func handleUsage() async throws -> Response {
        let apiKey = CaldwellConfig.shared.apiKey
        guard !apiKey.isEmpty else {
            return try Self.json(UsageResponse(
                characters_used: nil,
                characters_limit: nil,
                next_reset_unix: nil,
                api_key_set: false,
                error: "ELEVENLABS_API_KEY not set"
            ))
        }

        do {
            return try Self.json(try await Self.fetchUsage(apiKey: apiKey))
        } catch {
            return try Self.json(UsageResponse(
                characters_used: nil,
                characters_limit: nil,
                next_reset_unix: nil,
                api_key_set: true,
                error: error.localizedDescription
            ))
        }
    }

    // MARK: - /canon/pick handler

    /// Context → list of candidate canon phrases. The first list is the
    /// always-on Polite pool; Potty mode adds the second list on top.
    /// Phrases here must match (byte-for-byte) what `warm-cache.sh` and
    /// `stop-hook.sh` use, otherwise the cache lookup misses.
    nonisolated private static let canonContexts: [String: (polite: [String], potty: [String])] = [
        "push": (
            polite: ["Pushed, Sir."],
            potty:  ["Fuckin' pushed."]
        ),
        "tests-pass": (
            polite: ["Tests passing."],
            potty:  ["Tests fuckin' passing."]
        ),
        "build-pass": (
            polite: ["Build's clean."],
            potty:  []
        ),
        "found": (
            polite: ["Found it, Sir."],
            potty:  []
        ),
        "fail": (
            polite: ["Cocked it up, Sir.", "Most regrettable, Sir."],
            potty:  ["Bollocks.", "Bloody hell, Sir.", "Cocked it up, Sir."]
        ),
        "done": (
            polite: ["Sorted, Sir.", "Sorted.", "Bit of a faff, that.", "Job's a good 'un, Sir."],
            potty:  ["Sorted, fuckin' done.", "Bloody well done, that.", "Job's a good 'un, Sir."]
        ),
        "start": (
            polite: ["Right then Sir.", "Right then Sir, on it.", "On it, Sir.", "Onto it.", "I'll have a look."],
            potty:  ["Right then Sir, fuckin' on it."]
        ),
        "ack": (
            polite: ["Quite, Sir.", "Most kind, Sir."],
            potty:  []
        ),
        "reassure": (
            polite: [],
            potty:  ["Sweet fuck-all to worry about, Sir."]
        ),
    ]

    nonisolated private static func handleCanonPick(
        request: Request,
        audioQueue: AudioQueueActor
    ) async throws -> Response {
        // Parse optional body — context defaults to "neutral" (union of all).
        var requestedContext = "neutral"
        if let bodyData = try? await request.body.collect(upTo: 64 * 1024),
           let body = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any],
           let ctx = body["context"] as? String,
           !ctx.isEmpty {
            requestedContext = ctx.lowercased()
        }

        let cfg = CaldwellConfig.shared

        // Mute respects the global setting — same as /speak.
        if cfg.isMuted {
            return Response(status: .noContent)
        }

        // Build the candidate pool for this context.
        let candidates = canonCandidates(for: requestedContext, expletives: cfg.expletivesEnabled)
        guard !candidates.isEmpty else {
            return Response(status: .noContent)
        }

        // Filter to those actually cached for the current voice.
        let voiceId = cfg.voiceId
        guard !voiceId.isEmpty else {
            return Response(status: .noContent)
        }
        let cached = candidates.compactMap { text -> (String, URL)? in
            guard let url = PhraseCache.shared.get(text: text, voiceId: voiceId) else { return nil }
            return (text, url)
        }
        guard !cached.isEmpty else {
            // No cached canon for this context — stay silent rather than
            // spend ElevenLabs credit on a guess.
            return Response(status: .noContent)
        }

        // Random pick from cached pool.
        let (text, sourceURL) = cached.randomElement()!
        let entryId = Self.nextEntryId()
        let tmpURL: URL
        do {
            tmpURL = try Self.copyCacheAudioToTemp(sourceURL: sourceURL, entryId: entryId)
        } catch {
            return try Self.json(ErrorResponse(error.localizedDescription), status: .internalServerError)
        }

        let entry = AudioEntry(
            id: entryId,
            text: text,
            voiceId: voiceId,
            voiceLabel: "Caldwell",
            createdAt: Date(),
            channel: nil,
            priority: false,
            fullText: text,
            isReplay: true,
            audioURL: tmpURL
        )

        let position = await audioQueue.enqueue(entry)
        if position == nil {
            // Canon is fire-and-forget — stay silent on drop. 204 is the
            // same shape Sir's stop-hook already tolerates.
            try? FileManager.default.removeItem(at: tmpURL)
            return Response(status: .noContent)
        }
        return try Self.json(CanonPickResponse(
            id: entryId,
            played: text,
            context: requestedContext,
            position: position,
            dropped: nil
        ))
    }

    /// Resolve a context tag into its candidate phrase list. "neutral"
    /// returns the union across all contexts. Unknown tags return [].
    nonisolated private static func canonCandidates(for context: String, expletives: Bool) -> [String] {
        if context == "neutral" {
            var pool: [String] = []
            for (_, lists) in canonContexts {
                pool.append(contentsOf: lists.polite)
                if expletives { pool.append(contentsOf: lists.potty) }
            }
            // De-dup while preserving order.
            var seen = Set<String>()
            return pool.filter { seen.insert($0).inserted }
        }
        guard let lists = canonContexts[context] else { return [] }
        var pool = lists.polite
        if expletives { pool.append(contentsOf: lists.potty) }
        return pool
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
        if cacheOnly, cachedURL != nil {
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
        let entryId = Self.nextEntryId()
        var entry = AudioEntry(
            id: entryId,
            text: String(text.prefix(100)),
            voiceId: voiceId,
            voiceLabel: "Caldwell",
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
            if let tmp = try? Self.copyCacheAudioToTemp(sourceURL: cached, entryId: entryId) {
                entry.audioURL = tmp
            }
        }

        let position = await audioQueue.enqueue(entry)

        // Queue full → drop without firing the ElevenLabs fetch. Critical:
        // skipping the fetch is what stops dropped lines from burning quota.
        if position == nil {
            return try Self.json(SpeakResponse(
                id: entryId,
                position: nil,
                voice: voiceId,
                text_preview: String(text.prefix(100)),
                dropped: true,
                reason: "busy"
            ))
        }

        // Cache miss: fetch in background, signal the worker when ready.
        if cachedURL == nil {
            let entryIdCopy = String(entryId)
            let textCopy = text
            let voiceIdCopy = voiceId
            let apiKey = cfg.apiKey
            // Cache eligibility: caller asked for it AND the text is short
            // enough to plausibly recur. Anything longer is almost certainly
            // session-specific (file paths, findings, one-shot prose) and
            // will never replay — caching it just bloats the LRU.
            let cacheEligible = cacheable && isCacheEligible(text: textCopy)
            Task.detached {
                do {
                    let url = try await ElevenLabsClient.fetchTTS(
                        text: textCopy, voiceId: voiceIdCopy, apiKey: apiKey
                    )
                    if cacheEligible {
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
            id: entryId,
            position: position,
            voice: voiceId,
            text_preview: String(text.prefix(100)),
            dropped: nil,
            reason: nil
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

    nonisolated private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    nonisolated private static func decodeBody<T: Decodable>(
        _ type: T.Type,
        from request: Request,
        maxBytes: Int = 1024 * 1024
    ) async throws -> T {
        let buffer = try await request.body.collect(upTo: maxBytes)
        return try JSONDecoder().decode(T.self, from: Data(buffer: buffer))
    }

    nonisolated private static func currentSettings() -> SettingsResponse {
        let config = CaldwellConfig.shared
        return SettingsResponse(
            voice_id: config.voiceId,
            api_key_set: !config.apiKey.isEmpty,
            muted: config.isMuted,
            expletives_enabled: config.expletivesEnabled
        )
    }

    nonisolated private static func nextEntryId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())
    }

    nonisolated private static func isValidPhraseCacheKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 64 && key.allSatisfy { $0.isHexDigit }
    }

    /// Phrase-cache admission policy. Caller-set `cacheable: true` is a hint,
    /// not a command — the daemon refuses to cache text that's obviously
    /// one-shot. Generic short canon ("Pushed, Sir.", "Build's clean.")
    /// passes; detailed Tier 3 lines do not.
    nonisolated static func isCacheEligible(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 60 { return false }
        if trimmed.contains("://") { return false }
        // Em-dash is the dead giveaway of a Tier 3 detailed alert.
        if trimmed.contains("—") { return false }
        // File extensions, PR/issue refs — session-specific by definition.
        let oneShotSubstrings = [".swift", ".ts", ".tsx", ".js", ".py", ".json",
                                 ".md", ".sh", ".plist", "PR #", "issue #"]
        for marker in oneShotSubstrings where trimmed.contains(marker) {
            return false
        }
        return true
    }

    nonisolated private static func loadPhraseSidecar(from url: URL) -> PhraseSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhraseSidecar.self, from: data)
    }

    nonisolated private static func savePhraseSidecar(_ value: PhraseSidecar, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url)
    }

    nonisolated private static func fileSize(at url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }

    nonisolated private static func copyCacheAudioToTemp(sourceURL: URL, entryId: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("caldwell-tts-\(entryId)-\(UUID().uuidString).mp3")
        try FileManager.default.copyItem(at: sourceURL, to: url)
        return url
    }

    nonisolated private static func ssePayload(event: String, json: String) -> String {
        "event: \(event)\ndata: \(json)\n\n"
    }

    nonisolated private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        default:
            return "application/octet-stream"
        }
    }

    nonisolated private static func legacyPortraitFilename(name: String, frame: String) -> String {
        switch frame.lowercased() {
        case "closed.png":
            return "\(name).png"
        case "slight.png":
            return "\(name)_slight.png"
        case "open.png":
            return "\(name)_open.png"
        default:
            return "\(name)_\(frame)"
        }
    }

    nonisolated private static func fetchUsage(apiKey: String) async throws -> UsageResponse {
        guard let url = URL(string: "\(CaldwellConfig.apiBase)/user") else {
            throw UsageFetchError("Invalid ElevenLabs URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError("Invalid response from ElevenLabs")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
            throw UsageFetchError("ElevenLabs HTTP \(http.statusCode): \(body)")
        }

        do {
            let payload = try JSONDecoder().decode(ElevenLabsUserEnvelope.self, from: data)
            return UsageResponse(
                characters_used: payload.subscription.character_count,
                characters_limit: payload.subscription.character_limit,
                next_reset_unix: payload.subscription.next_character_count_reset_unix,
                api_key_set: true,
                error: nil
            )
        } catch {
            throw UsageFetchError("Invalid ElevenLabs response: \(error.localizedDescription)")
        }
    }
}

// MARK: - Response models

private struct UsageFetchError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

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
    let position: Int?
    let voice: String
    let text_preview: String
    let dropped: Bool?
    let reason: String?
}

private struct CacheOnlyResponse: Encodable, Sendable {
    let cached: Bool
    let fresh: Bool
    let key: String
    let char_count: Int
}

private struct HistoryResponseItem: Encodable, Sendable {
    let id: String
    let voice: String
    let text: String
    let channel: String?
    let timestamp: Double
    let duration: Double?
    let failed: Bool

    init(_ item: HistoryItem) {
        self.id = item.id
        self.voice = item.voice
        self.text = item.text
        self.channel = item.channel
        self.timestamp = item.timestamp.timeIntervalSince1970
        self.duration = item.duration
        self.failed = item.failed
    }
}

private struct CachedPhraseRecord: Codable, Sendable {
    let key: String
    let text: String
    let voice_id: String
    let char_count: Int
    let created_at: Double
    let play_count: Int
}

private struct CachePhrasesResponse: Encodable, Sendable {
    let phrases: [CachedPhraseRecord]
    let count: Int
    let total_bytes: Int
    let max_bytes: Int
}

private struct PhraseSidecar: Codable, Sendable {
    let key: String
    let text: String
    let voice_id: String
    var voice_label: String?
    let char_count: Int
    let created_at: Double
    var first_cached_at: Double?
    var last_played_at: Double?
    var play_count: Int

    var responseRecord: CachedPhraseRecord {
        CachedPhraseRecord(
            key: key,
            text: text,
            voice_id: voice_id,
            char_count: char_count,
            created_at: created_at,
            play_count: play_count
        )
    }

    enum CodingKeys: String, CodingKey {
        case key
        case text
        case voice_id
        case voice_label
        case char_count
        case created_at
        case first_cached_at
        case last_played_at
        case play_count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.voice_id = try container.decodeIfPresent(String.self, forKey: .voice_id) ?? ""
        self.voice_label = try container.decodeIfPresent(String.self, forKey: .voice_label)
        self.char_count = try container.decodeIfPresent(Int.self, forKey: .char_count) ?? 0
        self.first_cached_at = try container.decodeIfPresent(Double.self, forKey: .first_cached_at)
        self.last_played_at = try container.decodeIfPresent(Double.self, forKey: .last_played_at)
        self.created_at = try container.decodeIfPresent(Double.self, forKey: .created_at)
            ?? self.first_cached_at
            ?? 0
        self.play_count = try container.decodeIfPresent(Int.self, forKey: .play_count) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(text, forKey: .text)
        try container.encode(voice_id, forKey: .voice_id)
        try container.encodeIfPresent(voice_label, forKey: .voice_label)
        try container.encode(char_count, forKey: .char_count)
        try container.encode(created_at, forKey: .created_at)
        try container.encode(first_cached_at ?? created_at, forKey: .first_cached_at)
        try container.encodeIfPresent(last_played_at, forKey: .last_played_at)
        try container.encode(play_count, forKey: .play_count)
    }
}

private struct DeletePhraseResponse: Encodable, Sendable {
    let deleted: Bool
}

private struct ClearCacheResponse: Encodable, Sendable {
    let cleared: Bool
    let count: Int
}

private struct CachePlayBody: Decodable, Sendable {
    let key: String
}

private struct CachePlayResponse: Encodable, Sendable {
    let id: String
    let position: Int?
    let dropped: Bool?
}

private struct CanonPickResponse: Encodable, Sendable {
    let id: String
    let played: String
    let context: String
    let position: Int?
    let dropped: Bool?
}

private struct SettingsResponse: Encodable, Sendable {
    let voice_id: String
    let api_key_set: Bool
    let muted: Bool
    let expletives_enabled: Bool
}

private struct SettingsUpdateRequest: Decodable, Sendable {
    let voice_id: String?
    let muted: Bool?
    let expletives_enabled: Bool?
    let api_key: String?
}

private struct UsageResponse: Encodable, Sendable {
    let characters_used: Int?
    let characters_limit: Int?
    let next_reset_unix: Int?
    let api_key_set: Bool
    let error: String?
}

private struct ElevenLabsUserEnvelope: Decodable, Sendable {
    let subscription: ElevenLabsSubscription
}

private struct ElevenLabsSubscription: Decodable, Sendable {
    let character_count: Int
    let character_limit: Int
    let next_character_count_reset_unix: Int
}
