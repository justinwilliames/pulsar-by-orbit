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
        // History lives in memory and starts empty, so any retained replay
        // audio on disk is orphaned from a prior run — clear it.
        await audioQueue.purgeHistoryAudioStore()
    }

    func start() {
        guard serverTask == nil else {
            NSLog("[PulsarHTTP] start() called while already running — ignoring")
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
                        serverName: "pulsar-http"
                    )
                )

                NSLog("[PulsarHTTP] starting on 127.0.0.1:\(port)")
                try await app.runService()
            } catch {
                NSLog("[PulsarHTTP] server crashed: \(error)")
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
                source: "swift",
                native_voice: NativeVoiceClient.bestVoice(),
                enhanced_installed: NativeVoiceClient.enhancedInstalled()
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

        // POST /history/replay — replay any history item from its retained
        // per-item audio. Works for EVERY entry, not just cached canon.
        router.post("/history/replay") { request, _ -> Response in
            return try await Self.handleHistoryReplay(request: request, audioQueue: audioQueue)
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
            return try await Self.handleSettingsPost(request: request, sseBroadcaster: sseBroadcaster)
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

    // MARK: - /history/replay handler

    /// Replay a history item from its retained per-item audio. Unlike the
    /// UI's cache-play button (which only works for phrase-cached canon),
    /// this resolves EVERY history entry via the per-item store written on
    /// playback. Replays are always free — no ElevenLabs call.
    nonisolated private static func handleHistoryReplay(
        request: Request,
        audioQueue: AudioQueueActor
    ) async throws -> Response {
        guard let bodyData = try? await request.body.collect(upTo: 64 * 1024),
              let body = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any]
        else {
            return try Self.json(ErrorResponse("Invalid JSON"), status: .badRequest)
        }
        guard let id = body["id"] as? String, !id.isEmpty else {
            return try Self.json(ErrorResponse("No id provided"), status: .badRequest)
        }

        guard let item = await audioQueue.findHistory(id: id) else {
            return try Self.json(ErrorResponse("Entry not found in history"), status: .notFound)
        }

        let audioURL = CaldwellConfig.shared.historyAudioDir.appendingPathComponent("\(id).mp3")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            // Item is in history but its audio isn't retained — only happens
            // for entries that failed to play (nothing was ever captured).
            return try Self.json(
                ErrorResponse("No audio retained for this entry (it may have failed to play)"),
                status: .notFound
            )
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
            text: String(item.text.prefix(100)),
            voiceId: "",
            voiceLabel: item.voice,
            createdAt: Date(),
            channel: item.channel,
            priority: false,
            fullText: item.text,
            isReplay: true,
            audioURL: tmpURL
        )

        let position = await audioQueue.enqueue(entry)
        if position == nil {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        return try Self.json(ReplayResponse(
            id: entryId,
            position: position,
            replaying: id,
            dropped: position == nil ? true : nil
        ))
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
        request: Request,
        sseBroadcaster: SSEBroadcaster
    ) async throws -> Response {
        let update: SettingsUpdateRequest
        do {
            update = try await Self.decodeBody(SettingsUpdateRequest.self, from: request)
        } catch {
            return try Self.json(ErrorResponse("Invalid JSON"), status: .badRequest)
        }

        guard update.muted != nil ||
                update.canon_enabled != nil ||
                update.native_voice != nil
        else {
            return try Self.json(ErrorResponse("No fields to update"), status: .badRequest)
        }

        let config = CaldwellConfig.shared

        do {
            if let muted = update.muted {
                try config.set("CALDWELL_MUTED", value: muted ? "1" : "0")
            }
            if let canon = update.canon_enabled {
                try config.set("CALDWELL_CANON_ENABLED", value: canon ? "1" : "0")
            }
            if let nv = update.native_voice {
                // Empty resets to auto; otherwise only accept an installed voice.
                let trimmed = nv.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || NativeVoiceClient.availableVoices().contains(where: {
                    $0.caseInsensitiveCompare(trimmed) == .orderedSame
                }) {
                    try config.set("CALDWELL_NATIVE_VOICE", value: trimmed)
                }
            }
        } catch {
            return try Self.json(ErrorResponse(error.localizedDescription), status: .internalServerError)
        }

        // Broadcast the new settings so connected UIs reflect the change at
        // once. Without this, a config write via the API (say.sh --mute, the
        // Stop hook, any external caller) never reaches the app, leaving the
        // menubar mute glyph stale — the icon and the actual state disagree.
        let settings = Self.currentSettings()
        if let data = try? JSONEncoder().encode(settings),
           let json = String(data: data, encoding: .utf8) {
            await sseBroadcaster.broadcast(event: "settings", json: json)
        }
        return try Self.json(settings)
    }

    // MARK: - /canon/pick handler

    /// Context → neutral status phrases. Single pool per context — no persona branching.
    ///
    /// "neutral" is a FIRST-CLASS context with its own generic-acknowledgement
    /// pool — it is NOT the union of every other context. Generic lines are safe
    /// after literally any turn; specifics only fire on a confident match.
    nonisolated private static let canonContexts: [String: [String]] = [
        "push": ["Pushed.", "Push complete.", "Changes pushed.", "Sent up.", "Push done."],
        "tests-pass": ["Tests passing.", "Tests green.", "All tests passed.", "Suite passing.", "Green."],
        "build-pass": ["Build complete.", "Build succeeded.", "Build green.", "Compiled clean.", "Clean build."],
        "found": ["Found it.", "Located.", "Got it.", "There it is.", "Identified."],
        "fail": ["That failed.", "Something errored.", "Check the output.", "Failed.", "Error — check logs."],
        "done": ["Done.", "Task complete.", "Finished.", "Ready.", "Complete."],
        "start": ["On it.", "Starting.", "Looking into it.", "In progress.", "Got it."],
        "ack": ["Noted.", "Got it.", "Understood.", "Confirmed.", "Acknowledged."],
        "reassure": ["All clear.", "No issues.", "Looking good.", "Nothing to worry about."],
        "neutral": ["Done.", "Ready.", "Complete.", "Finished.", "Task complete.", "Noted.", "Got it."],
    ]

    /// Anti-repeat: the exact canon line we last played. When the chosen
    /// context has more than one cached candidate, the picker drops this line
    /// from the pool so Caldwell never fires the same phrase twice running.
    /// Guarded by `canonLock` — the pick path is `nonisolated static`.
    nonisolated(unsafe) private static var lastCanonText: String?
    nonisolated private static let canonLock = NSLock()

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

        // Message-style: cached pings off → bespoke-only, no canon turn-end ping.
        if !cfg.canonEnabled {
            return Response(status: .noContent)
        }

        // Build the candidate pool for this context.
        let candidates = canonCandidates(for: requestedContext)
        guard !candidates.isEmpty else {
            return Response(status: .noContent)
        }

        // Anti-repeat: if the pool has alternatives, never replay the exact
        // line we played last time. Falls back to the full pool when the
        // last line is the only option.
        let lastPlayed = Self.canonLock.withLock { Self.lastCanonText }
        var pickable = candidates
        if pickable.count > 1, let lastPlayed {
            let fresh = pickable.filter { $0 != lastPlayed }
            if !fresh.isEmpty { pickable = fresh }
        }
        let text = pickable.randomElement()!
        Self.canonLock.withLock { Self.lastCanonText = text }

        // Synthesise locally via macOS native voice — mirrors the /speak path.
        // No network, no API key, no spend.
        let entryId = Self.nextEntryId()
        let entry = AudioEntry(
            id: entryId,
            text: String(text.prefix(100)),
            voiceId: "native",
            voiceLabel: "Pulsar",
            createdAt: Date(),
            channel: nil,
            priority: false,
            fullText: text,
            isReplay: false,
            audioURL: nil,
            engine: "native"
        )

        guard let position = await audioQueue.enqueue(entry) else {
            // Canon is fire-and-forget — stay silent on drop.
            return Response(status: .noContent)
        }
        let idCopy = entryId
        let textCopy = text
        Task.detached {
            do {
                let url = try await NativeVoiceClient.synth(text: textCopy)
                await audioQueue.markReady(id: idCopy, url: url)
            } catch {
                NSLog("[PulsarHTTP] canon native synth failed for \(idCopy): \(error)")
                await audioQueue.markFailed(id: idCopy)
            }
        }
        return try Self.json(CanonPickResponse(
            id: entryId,
            played: text,
            context: requestedContext,
            position: position,
            dropped: nil
        ))
    }

    /// Resolve a context tag into its candidate phrase list. Every context —
    /// including "neutral" — is a key in `canonContexts`, so this is a plain
    /// lookup. Unknown tags (anything the skill passes that we don’t
    /// recognise) return [], so the picker stays silent rather than guessing.
    nonisolated private static func canonCandidates(for context: String) -> [String] {
        return canonContexts[context] ?? []
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

        let channel  = body["channel"]  as? String
        let priority = body["priority"] as? Bool ?? false

        // macOS local voice — synthesise via `say` to a temp AIFF so it plays
        // through the same envelope/lip-sync path. No network, no API key, no
        // spend. (ElevenLabs removed.)
        let entryId = Self.nextEntryId()
        let entry = AudioEntry(
            id: entryId, text: String(text.prefix(100)), voiceId: "native",
            voiceLabel: "Pulsar", createdAt: Date(), channel: channel,
            priority: priority, fullText: text, isReplay: false,
            audioURL: nil, engine: "native")
        guard let position = await audioQueue.enqueue(entry) else {
            return try Self.json(SpeakResponse(
                id: entryId, position: nil, voice: "native",
                text_preview: String(text.prefix(100)), dropped: true, reason: "busy"))
        }
        let idCopy = entryId
        let textCopy = text
        Task.detached {
            do {
                let url = try await NativeVoiceClient.synth(text: textCopy)
                await audioQueue.markReady(id: idCopy, url: url)
            } catch {
                NSLog("[PulsarHTTP] native synth failed for \(idCopy): \(error)")
                await audioQueue.markFailed(id: idCopy)
            }
        }
        return try Self.json(SpeakResponse(
            id: entryId, position: position, voice: "native",
            text_preview: String(text.prefix(100)), dropped: nil, reason: "native"))
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
            muted: config.isMuted,
            native_voice: NativeVoiceClient.bestVoice(),
            enhanced_installed: NativeVoiceClient.enhancedInstalled(),
            canon_enabled: config.canonEnabled,
            available_voices: NativeVoiceClient.voiceOptions()
        )
    }

    nonisolated private static func nextEntryId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())
    }

    nonisolated private static func isValidPhraseCacheKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 64 && key.allSatisfy { $0.isHexDigit }
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
            .appendingPathComponent("pulsar-tts-\(entryId)-\(UUID().uuidString).mp3")
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

}

// MARK: - Response models

private struct HealthResponse: Encodable, Sendable {
    let status: String
    let version: String
    let queue_size: Int
    let source: String
    let native_voice: String
    let enhanced_installed: Bool
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

private struct ReplayResponse: Encodable, Sendable {
    let id: String
    let position: Int?
    let replaying: String
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
    let muted: Bool
    let native_voice: String
    let enhanced_installed: Bool
    let canon_enabled: Bool
    let available_voices: [NativeVoiceClient.VoiceOption]
}

private struct SettingsUpdateRequest: Decodable, Sendable {
    let muted: Bool?
    let canon_enabled: Bool?
    let native_voice: String?
}
