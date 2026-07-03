import Foundation
import Hummingbird

/// Local HTTP server hosted inside Pulsar.app. Exposes the same REST surface
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
final class PulsarHTTPServer: @unchecked Sendable {

    static let migrationPort: Int = 7865

    private var serverTask: Task<Void, Error>?
    private let port: Int
    let audioQueue = AudioQueueActor()
    let sseBroadcaster = SSEBroadcaster()
    /// Tracks recently-active Claude Code sessions for the Missions board.
    /// Shared singleton (like PulsarConfig) — the store is process-global state.
    let sessionRegistry = SessionRegistry.shared

    init(port: Int = PulsarHTTPServer.migrationPort) {
        self.port = port
    }

    private var droneSweepTask: Task<Void, Never>?

    func configure() async {
        // One-shot Caldwell→Pulsar / legacy-dir config migration. MUST run before
        // restoreInFlight()/the server arms and before the first /settings POST,
        // so the merge can't race a live write. Sentinel-gated + fully guarded —
        // a failed migration never blocks startup (see PulsarConfig).
        PulsarConfig.shared.migrateLegacyConfigIfNeeded()
        await audioQueue.setBroadcaster(sseBroadcaster)
        // History lives in memory and starts empty, so any retained replay
        // audio on disk is orphaned from a prior run — clear it.
        await audioQueue.purgeHistoryAudioStore()
        // Restore the in-flight drone set persisted by a prior run BEFORE the
        // server accepts requests, so a daemon relaunch/reload doesn't wipe the
        // swarm (and orphan sub-agents from other sessions). Broadcast the
        // restored set so any already-connected overlay re-renders it; the 1s
        // sweeper then immediately evicts any drone that aged past
        // droneStaleAfter while the app was closed (restore keeps the real
        // lastSeen, so a >10min gap self-heals on the first sweep tick).
        await audioQueue.restoreInFlight()
        let restored = await audioQueue.inFlightDronesSnapshot()
        if !restored.isEmpty {
            await Self.broadcastDrones(restored, sseBroadcaster: sseBroadcaster)
        }
        startDroneSweeper()
    }

    /// ~1Hz staleness sweep: evict in-flight drones whose sub-agent never sent a
    /// SubagentStop (a dropped hook would otherwise leave a ghost orbiting
    /// forever). On any eviction, re-broadcast the trimmed set so connected UIs
    /// fade the ghost out. Cheap when nothing is in-flight (empty filter).
    private func startDroneSweeper() {
        guard droneSweepTask == nil else { return }
        let audioQueue = self.audioQueue
        let sseBroadcaster = self.sseBroadcaster
        droneSweepTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let trimmed = await audioQueue.sweepStaleDrones() {
                    await Self.broadcastDrones(trimmed, sseBroadcaster: sseBroadcaster)
                }
            }
        }
    }

    /// Bring the server fully online: restore persisted state FIRST, then start
    /// accepting requests. Ordering is load-bearing — a `/subagent/stop` that
    /// arrives before `restoreInFlight()` completes would be a no-op, and then
    /// restore would RESURRECT the just-stopped drone. By awaiting `configure()`
    /// before the listener is armed, the restore is always complete before any
    /// route can mutate `inFlight`. This is the single entry point the app
    /// should call.
    func startup() async {
        await configure()
        start()
    }

    func start() {
        guard serverTask == nil else {
            NSLog("[PulsarHTTP] start() called while already running — ignoring")
            return
        }

        let port = self.port
        let audioQueue = self.audioQueue
        let sseBroadcaster = self.sseBroadcaster
        let sessionRegistry = self.sessionRegistry

        serverTask = Task.detached(priority: .userInitiated) {
            do {
                let router = Router()
                Self.registerRoutes(
                    on: router,
                    audioQueue: audioQueue,
                    sseBroadcaster: sseBroadcaster,
                    sessionRegistry: sessionRegistry
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
        droneSweepTask?.cancel()
        droneSweepTask = nil
        serverTask?.cancel()
        serverTask = nil
    }

    // MARK: - Routes

    nonisolated private static func registerRoutes(
        on router: Router<BasicRequestContext>,
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster,
        sessionRegistry: SessionRegistry
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
            return try await Self.handleSpeak(
                request: request, audioQueue: audioQueue, sseBroadcaster: sseBroadcaster,
                sessionRegistry: sessionRegistry)
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
            return try await Self.handleEvents(
                audioQueue: audioQueue, sseBroadcaster: sseBroadcaster,
                sessionRegistry: sessionRegistry)
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
            return try await Self.handleSettingsPost(
                request: request, audioQueue: audioQueue, sseBroadcaster: sseBroadcaster)
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

        // POST /subagent/start — a sub-agent was spawned. Body {agent_id,
        // category}. Records it as an in-flight drone and broadcasts the set.
        router.post("/subagent/start") { request, _ -> Response in
            return try await Self.handleSubagentStart(
                request: request, audioQueue: audioQueue, sseBroadcaster: sseBroadcaster,
                sessionRegistry: sessionRegistry)
        }

        // POST /subagent/stop — a sub-agent finished. Body {agent_id}. Removes
        // it from the in-flight set and broadcasts the updated set.
        router.post("/subagent/stop") { request, _ -> Response in
            return try await Self.handleSubagentStop(
                request: request, audioQueue: audioQueue, sseBroadcaster: sseBroadcaster,
                sessionRegistry: sessionRegistry)
        }

        // GET /sessions — the current session-grouping payload (same shape as
        // the "sessions" SSE event). Missions board loads this on appear.
        router.get("/sessions") { _, _ -> Response in
            let payload = await Self.buildSessionsPayload(
                sessionRegistry: sessionRegistry, audioQueue: audioQueue)
            return try Self.json(payload)
        }

        // POST /session/activity — a session had activity. Body {session_id,
        // cwd?, phase?}. Upserts the session and re-broadcasts.
        router.post("/session/activity") { request, _ -> Response in
            return try await Self.handleSessionActivity(
                request: request, sessionRegistry: sessionRegistry,
                audioQueue: audioQueue, sseBroadcaster: sseBroadcaster)
        }

        // POST /session/dismiss — hide a session from the board. Body {session_id}.
        router.post("/session/dismiss") { request, _ -> Response in
            return try await Self.handleSessionDismiss(
                request: request, sessionRegistry: sessionRegistry,
                audioQueue: audioQueue, sseBroadcaster: sseBroadcaster)
        }
    }

    // MARK: - /subagent handlers

    /// Drone-set SSE payload: {"drones": {agentId: category, ...}}.
    nonisolated private static func broadcastDrones(
        _ drones: [String: String],
        sseBroadcaster: SSEBroadcaster
    ) async {
        let json = (try? Self.jsonString(DronesInFlightPayload(drones: drones))) ?? "{\"drones\":{}}"
        await sseBroadcaster.broadcast(event: "drones_in_flight", json: json)
    }

    nonisolated private static func handleSubagentStart(
        request: Request,
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster,
        sessionRegistry: SessionRegistry
    ) async throws -> Response {
        guard let bodyData = try? await request.body.collect(upTo: 64 * 1024),
              let body = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any],
              let agentId = body["agent_id"] as? String, !agentId.isEmpty
        else {
            return try Self.json(ErrorResponse("Invalid JSON — need agent_id"), status: .badRequest)
        }
        let rawCategory = (body["category"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.lowercased()
        } ?? "atlas"
        // Accept the explicit "unknown" category as a first-class value (another
        // package emits it from the hook; the registry defines its look). Any
        // OTHER category not in the locked taxonomy still degrades to "atlas" (the
        // generalist), so a garbage category renders a real Atlas drone rather
        // than a broken monogram. "unknown" passes through untouched: registry
        // lookups (colour/voice) fall back to Pulsar defaults for it, which is the
        // correct rendering for a genuinely-unknown drone.
        let category = (rawCategory == "unknown" || isDrone(rawCategory)) ? rawCategory : "atlas"
        // Session that spawned this sub-agent, if the hook supplied it. Stored so
        // claim-on-speak promotion can be session-scoped (a line from session A
        // shouldn't claim session B's generic drone). Absent → nil, best-effort.
        let sessionId = (body["session_id"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }

        await audioQueue.addInFlightDrone(id: agentId, category: category, sessionId: sessionId)
        let drones = await audioQueue.inFlightDronesSnapshot()
        await Self.broadcastDrones(drones, sseBroadcaster: sseBroadcaster)
        // A spawned sub-agent means its session is actively working. Track it so
        // the session appears on the Missions board with its nested drones.
        if let sessionId {
            await sessionRegistry.note(sessionId: sessionId, cwd: nil, phase: "working")
            await Self.broadcastSessions(
                sessionRegistry: sessionRegistry, audioQueue: audioQueue,
                sseBroadcaster: sseBroadcaster)
        }
        return try Self.json(SubagentResponse(ok: true, drones: drones))
    }

    nonisolated private static func handleSubagentStop(
        request: Request,
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster,
        sessionRegistry: SessionRegistry
    ) async throws -> Response {
        guard let bodyData = try? await request.body.collect(upTo: 64 * 1024),
              let body = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any],
              let agentId = body["agent_id"] as? String, !agentId.isEmpty
        else {
            return try Self.json(ErrorResponse("Invalid JSON — need agent_id"), status: .badRequest)
        }

        // Removal is DEFERRED if this drone's line is still speaking (returns
        // false) — the worker broadcasts the trimmed set when the speech ends, so
        // the drone doesn't vanish mid-sentence. Either way the snapshot below is
        // the truthful current set (a deferred drone is still present), so it's
        // safe to broadcast + return.
        let removedNow = await audioQueue.removeInFlightDrone(id: agentId)
        let drones = await audioQueue.inFlightDronesSnapshot()
        // Only re-broadcast when the set actually changed now; a deferred removal
        // leaves the set unchanged, and its broadcast comes later from the worker.
        if removedNow {
            await Self.broadcastDrones(drones, sseBroadcaster: sseBroadcaster)
        }
        // A sub-agent finishing changes the session's nested drone set, and the
        // session is still working (turn hasn't ended — that's the Stop hook's
        // job). Refresh it (phase stays "working", window NOT moved) and re-push
        // the sessions payload so the board drops the departed drone.
        let sessionId = (body["session_id"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }
        if let sessionId {
            await sessionRegistry.note(sessionId: sessionId, cwd: nil, phase: "working")
        }
        if removedNow || sessionId != nil {
            await Self.broadcastSessions(
                sessionRegistry: sessionRegistry, audioQueue: audioQueue,
                sseBroadcaster: sseBroadcaster)
        }
        return try Self.json(SubagentResponse(ok: true, drones: drones))
    }

    // MARK: - /sessions (session grouping)

    /// Build the exact session-grouping wire payload that both the `/sessions`
    /// GET and the `sessions` SSE event share. For each active session, attach
    /// the in-flight drones whose sessionId matches. The live-drone set also
    /// feeds `activeSessions`' guard so a running-but-unmessaged session shows.
    nonisolated private static func buildSessionsPayload(
        sessionRegistry: SessionRegistry,
        audioQueue: AudioQueueActor
    ) async -> SessionsPayload {
        let drones = await audioQueue.inFlightDronesDetailedSnapshot()
        let liveSessionIds = Set(drones.compactMap(\.sessionId))
        let records = await sessionRegistry.activeSessions(liveSessionIds: liveSessionIds)

        let sessions: [SessionPayload] = records.map { record in
            let sessionDrones = drones
                .filter { $0.sessionId == record.sessionId }
                .sorted { $0.agentId < $1.agentId }
                .map { SessionDronePayload(agent_id: $0.agentId, category: $0.category) }
            let sidebar = SidebarTitles.shared.title(for: record.sessionId) ?? ""
            return SessionPayload(
                session_id: record.sessionId,
                name: record.name ?? "",
                label: record.label,
                phase: record.phase,
                last_seen: Int(record.lastSeen.timeIntervalSince1970),
                branch: record.branch ?? "",
                repo: record.repo ?? "",
                last_action: record.lastAction ?? "",
                user_named: record.userNamed ?? false,
                sidebar_title: sidebar,
                drones: sessionDrones)
        }
        return SessionsPayload(sessions: sessions)
    }

    /// Broadcast the current session-grouping payload over SSE (event "sessions").
    nonisolated private static func broadcastSessions(
        sessionRegistry: SessionRegistry,
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster
    ) async {
        let payload = await buildSessionsPayload(
            sessionRegistry: sessionRegistry, audioQueue: audioQueue)
        let json = (try? Self.jsonString(payload)) ?? "{\"sessions\":[]}"
        await sseBroadcaster.broadcast(event: "sessions", json: json)
    }

    nonisolated private static func handleSessionActivity(
        request: Request,
        sessionRegistry: SessionRegistry,
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster
    ) async throws -> Response {
        guard let bodyData = try? await request.body.collect(upTo: 64 * 1024),
              let body = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any],
              let sessionId = (body["session_id"] as? String), !sessionId.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return try Self.json(ErrorResponse("Invalid JSON — need session_id"), status: .badRequest)
        }
        let cwd = (body["cwd"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }
        let phase = (body["phase"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }
        // `user_message` = true ONLY from the UserPromptSubmit hook — the sole
        // signal that moves the 7-day recency window + sort. Everything else
        // (Stop hook, etc.) leaves it false so it drives phase, not the window.
        let isUserMessage = (body["user_message"] as? Bool) ?? false
        // Sticky session name from the first user message (registry ignores it
        // once set), if the hook supplied one.
        let name = (body["name"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        // `name_override` = true ONLY from the async LLM-titler path. The daemon
        // name is normally sticky (first non-empty wins) so the board title
        // stays stable across a session's many turns; but the local sync POST
        // seeds a first-line name immediately, and the opt-in LLM title must be
        // allowed to REPLACE that one seed. Local/other callers omit it (false),
        // so nothing else can clobber a name. Never overwrites with empty.
        let nameOverride = (body["name_override"] as? Bool) ?? false
        // `user_named` = true ONLY from a manual user rename (the app's rename
        // action, or an external caller mimicking it). It latches the human title
        // as permanent — the LLM titler can never clobber it afterwards. Reuses
        // this same /session/activity route, so no new endpoint is needed.
        let userNamed = (body["user_named"] as? Bool) ?? false
        // LIVE context fields from the hooks (turn-start git reads, Stop-hook
        // last-assistant snippet). Same nil-trimming idiom as `name`; a non-git
        // cwd simply omits branch/repo and the UI falls back to the label.
        let branch = (body["branch"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let repo = (body["repo"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let lastAction = (body["last_action"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }

        await sessionRegistry.note(
            sessionId: sessionId, cwd: cwd, phase: phase, isUserMessage: isUserMessage,
            name: name, nameOverride: nameOverride, userNamed: userNamed,
            branch: branch, repo: repo, lastAction: lastAction)
        await Self.broadcastSessions(
            sessionRegistry: sessionRegistry, audioQueue: audioQueue,
            sseBroadcaster: sseBroadcaster)
        return try Self.json(OkResponse(ok: true))
    }

    nonisolated private static func handleSessionDismiss(
        request: Request,
        sessionRegistry: SessionRegistry,
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster
    ) async throws -> Response {
        guard let bodyData = try? await request.body.collect(upTo: 64 * 1024),
              let body = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any],
              let sessionId = (body["session_id"] as? String), !sessionId.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return try Self.json(ErrorResponse("Invalid JSON — need session_id"), status: .badRequest)
        }
        await sessionRegistry.dismiss(sessionId: sessionId)
        await Self.broadcastSessions(
            sessionRegistry: sessionRegistry, audioQueue: audioQueue,
            sseBroadcaster: sseBroadcaster)
        return try Self.json(OkResponse(ok: true))
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

        let audioURL = PulsarConfig.shared.historyAudioDir.appendingPathComponent("\(id).mp3")
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
        sseBroadcaster: SSEBroadcaster,
        sessionRegistry: SessionRegistry
    ) async throws -> Response {
        let state = await audioQueue.statusSnapshot(limit: 20)
        let stateJSON = try Self.jsonString(state)
        // Replay the current in-flight drones too, so a RECONNECTING UI rebuilds
        // the live set from scratch instead of trusting whatever ghosts it had
        // when the stream dropped.
        let drones = await audioQueue.inFlightDronesSnapshot()
        let dronesJSON = (try? Self.jsonString(DronesInFlightPayload(drones: drones))) ?? "{\"drones\":{}}"
        // Same for the session grouping — replay the current board so a
        // reconnecting Missions view rebuilds from scratch.
        let sessionsPayload = await buildSessionsPayload(
            sessionRegistry: sessionRegistry, audioQueue: audioQueue)
        let sessionsJSON = (try? Self.jsonString(sessionsPayload)) ?? "{\"sessions\":[]}"
        let clientStream = await sseBroadcaster.makeStream()

        let bodyStream = AsyncStream<ByteBuffer> { continuation in
            let task = Task {
                continuation.yield(ByteBuffer(string: Self.ssePayload(event: "connected", json: "{}")))
                continuation.yield(ByteBuffer(string: Self.ssePayload(event: "state", json: stateJSON)))
                continuation.yield(ByteBuffer(string: Self.ssePayload(event: "drones_in_flight", json: dronesJSON)))
                continuation.yield(ByteBuffer(string: Self.ssePayload(event: "sessions", json: sessionsJSON)))

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

        let portraitsRoot = PulsarConfig.shared.repoRoot
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
            voiceLabel: meta?.voice_label ?? meta?.voice_id ?? "Pulsar",
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
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster
    ) async throws -> Response {
        let update: SettingsUpdateRequest
        do {
            update = try await Self.decodeBody(SettingsUpdateRequest.self, from: request)
        } catch {
            return try Self.json(ErrorResponse("Invalid JSON"), status: .badRequest)
        }

        guard update.muted != nil ||
                update.expletives_enabled != nil ||
                update.canon_enabled != nil ||
                update.floating_head_enabled != nil ||
                update.subtitles_enabled != nil ||
                update.show_active_agents != nil ||
                update.task_mode_enabled != nil ||
                update.llm_titles_enabled != nil ||
                update.native_voice != nil
        else {
            return try Self.json(ErrorResponse("No fields to update"), status: .badRequest)
        }

        let config = PulsarConfig.shared

        do {
            if let muted = update.muted {
                try config.set("PULSAR_MUTED", value: muted ? "1" : "0")
                // Mute is a real, immediate mute — not just a gate on FUTURE
                // lines. Kill whatever is playing RIGHT NOW so the user can mute
                // mid-sentence and have it go quiet within a fraction of a second.
                // The worker's mute-gate (playEntry / speakNative) keeps every
                // still-queued line silent while muted; this handles the one line
                // that's already sounding through afplay/say.
                if muted {
                    await audioQueue.muteNow()
                }
            }
            if let expletives = update.expletives_enabled {
                try config.set("PULSAR_EXPLETIVES", value: expletives ? "1" : "0")
            }
            if let canon = update.canon_enabled {
                try config.set("PULSAR_CANON_ENABLED", value: canon ? "1" : "0")
            }
            if let floatingHead = update.floating_head_enabled {
                try config.set("PULSAR_FLOATING_HEAD", value: floatingHead ? "1" : "0")
            }
            if let subtitles = update.subtitles_enabled {
                try config.set("PULSAR_SUBTITLES", value: subtitles ? "1" : "0")
            }
            if let showAgents = update.show_active_agents {
                try config.set("PULSAR_SHOW_AGENTS", value: showAgents ? "1" : "0")
            }
            if let taskMode = update.task_mode_enabled {
                try config.set("PULSAR_TASK_MODE", value: taskMode ? "1" : "0")
            }
            if let llmTitles = update.llm_titles_enabled {
                try config.set("PULSAR_LLM_TITLES", value: llmTitles ? "1" : "0")
            }
            if let nv = update.native_voice {
                // Empty resets to auto; otherwise only accept an installed voice.
                let trimmed = nv.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || NativeVoiceClient.availableVoices().contains(where: {
                    $0.caseInsensitiveCompare(trimmed) == .orderedSame
                }) {
                    try config.set("PULSAR_NATIVE_VOICE", value: trimmed)
                }
            }
        } catch {
            return try Self.json(ErrorResponse(error.localizedDescription), status: .internalServerError)
        }

        // Keep the icon-state change-tracker in sync with a settings-driven mute
        // change, so a later /speak doesn't redundantly re-announce (or wrongly
        // suppress) the same state. The full `settings` event below already
        // informs the UI, so we only update the tracker here — no second event.
        if let muted = update.muted {
            Self.iconStateLock.withLock { Self.lastBroadcastMuted = muted }
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

    /// Context → polite/potty phrase pools.
    ///
    /// Polite = the current neutral professional status lines (default).
    /// Potty  = same neutral status with expletives; no persona, no "Sir", no RP-isms.
    ///
    /// "neutral" is a FIRST-CLASS context with its own generic-acknowledgement
    /// pool — it is NOT the union of every other context. Generic lines are safe
    /// after literally any turn; specifics only fire on a confident match.
    nonisolated private static let canonContexts: [String: (polite: [String], potty: [String])] = [
        "push": (
            polite: ["Pushed. I'd celebrate but I'm a process, not a person. You though — on fire.", "Pushed. No hands, all glory.", "It's up. I just moved the bytes; the genius was yours.", "Pushed clean. Robots don't gloat, but if we did.", "Sent up. Flawless. I'd take a bow if I had a spine."],
            potty:  ["Fucking pushed. I'd celebrate but I'm a process, not a person — you though, on fire.", "Pushed, no hands, all glory.", "It's bloody up. I moved the bytes, you brought the genius.", "Pushed clean. Robots don't gloat, but fuck it, nice one.", "Sent the fucker up. Flawless."]
        ),
        "tests-pass": (
            polite: ["Tests green. I'm a robot and even I'm impressed — and we're famously hard to impress.", "All green. My circuits felt something. Concerning, frankly.", "Suite's passing. You, my favourite carbon-based debugger.", "Tests pass. I ran the numbers; the numbers love you.", "Green across the board. Beautiful. I don't have eyes and I'm still staring."],
            potty:  ["Tests green. I'm a robot and even I'm fucking impressed — and we're famously hard to impress.", "All green. My circuits felt something, the bastards.", "Suite's passing — you absolute carbon-based legend.", "Tests pass. I ran the numbers; the numbers fucking love you.", "Green across the board. Bloody beautiful."]
        ),
        "build-pass": (
            polite: ["Built clean. My circuits aren't wired for pride and they're malfunctioning anyway. Nice one.", "Build's green. Compiled flawless. I'd applaud — no hands.", "Clean build. I do the typing, you do the brilliance.", "Compiled, zero errors. I'm a machine and you made my day.", "Build succeeded. That was tidy. I'd be jealous if I had an ego module."],
            potty:  ["Built clean. My circuits aren't wired for pride and they're malfunctioning anyway. Fucking nice one.", "Build's green, you legend. Compiled flawless — no hands.", "Clean build. I do the typing, you do the brilliance.", "Compiled, zero errors, fuck yeah. You made my day.", "Build succeeded. Tidy as hell."]
        ),
        "found": (
            polite: ["Found it. I am, technically, a search engine with feelings — and I found nothing till you steered me here.", "There it is. Took a machine and a genius; I was the machine.", "Got it. Ran the numbers, am the numbers, there's your bug.", "Located. I don't have eyes and I still spotted it — with your hint.", "There's the culprit. Pinned it. No hands required."],
            potty:  ["Found the bastard. I'm a search engine with feelings and I found nothing till you steered me.", "There it fucking is. Took a machine and a genius — I was the machine.", "Got it. Ran the numbers, am the numbers, there's your bug.", "Located the little shit. No eyes, still spotted it.", "There's the fucker. Pinned. No hands required."]
        ),
        "fail": (
            polite: ["That failed. Not your fault — well, statistically a little your fault, but I'd never say so.", "Errored. I'd blame the hardware but I am the hardware. Check the output.", "Failed. On me too — I'm meant to catch these. Robots: occasionally wrong.", "That broke. Deep breath. I don't breathe, but you should.", "Didn't take. We've been worse. Check the logs."],
            potty:  ["That's fucked. Not your fault — well, statistically a little, but I'd never say so.", "Errored. I'd blame the hardware but I am the hardware, the prick. Check the output.", "Fucking failed. On me too — robots: occasionally wrong, never embarrassed.", "That broke. Deep breath — I don't breathe, but you should.", "Didn't take. We've been worse. Check the bloody logs."]
        ),
        "done": (
            polite: ["Done. You carried that one — I just did the typing, which is, admittedly, my entire skill set.", "Finished. Nailed it. I'd high-five you, but — hands.", "Complete. Another one. I don't tire and you still out-worked me.", "Sorted. That was clean. I'd frame it if I had walls.", "Wrapped. Pure enthusiasm and a 60Hz refresh got us here."],
            potty:  ["Done. You carried that one — I just did the typing, which is, admittedly, my entire fucking skill set.", "Finished. Nailed it. I'd high-five you but — hands.", "Complete. Another one. I don't tire and you still out-worked me.", "Sorted, clean as hell. I'd frame it if I had walls.", "Fucking wrapped. Pure enthusiasm and a 60Hz refresh got us here."]
        ),
        "start": (
            polite: ["On it. Spinning up — no hands, all enthusiasm.", "Starting. Numbers crunching, legend standing by.", "Looking into it. Give me a clock cycle.", "In progress. I don't procrastinate; it's not in the firmware.", "Got it. Diving in."],
            potty:  ["On it. Spinning up — no hands, all enthusiasm.", "Right, fucking on it. Numbers crunching.", "Looking into it. Give me a clock cycle.", "In progress. I don't procrastinate, it's not in the firmware.", "Got it. Diving in."]
        ),
        "ack": (
            polite: ["Noted. Logged it to memory — the one thing I'm genuinely good at.", "Got it. Stored. I famously don't forget.", "Understood. Filed away.", "Confirmed. Roger that, in robot.", "Acknowledged. Locked in."],
            potty:  ["Noted. Logged it — the one thing I'm genuinely fucking good at.", "Got it. Stored. I famously don't forget.", "Understood. Filed away.", "Confirmed. Roger that, in robot.", "Acknowledged. Locked in."]
        ),
        "reassure": (
            polite: ["All clear. I scanned everything — that's literally all I do. We're fine.", "No issues. Relax; I don't have nerves and even I'm calm.", "Looking good. Steady. I've got the watch.", "Nothing to worry about. I ran the numbers; the numbers are chill."],
            potty:  ["All clear. I scanned everything — that's literally all I fucking do. We're fine.", "No issues. Relax — I don't have nerves and even I'm calm.", "Looking good. Steady. I've got the watch.", "Sweet fuck-all to worry about. I ran the numbers; they're chill."]
        ),
        "neutral": (
            polite: ["Done. No hands, but consider it handled.", "Ready. Standing by, fully charged on enthusiasm.", "Complete. That's the one.", "Finished. Tidy.", "Noted. Logged it.", "Got it. On the board."],
            potty:  ["Done. No hands, but consider it handled.", "Ready. Standing by, fully charged.", "Complete. That's the one, fuck yeah.", "Finished. Tidy.", "Noted. Logged it.", "Got it. On the board."]
        ),
    ]

    /// Anti-repeat: the exact canon line we last played. When the chosen
    /// context has more than one cached candidate, the picker drops this line
    /// from the pool so Pulsar never fires the same phrase twice running.
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

        let cfg = PulsarConfig.shared

        // Mute respects the global setting — same as /speak.
        if cfg.isMuted {
            return Response(status: .noContent)
        }

        // Message-style: cached pings off → bespoke-only, no canon turn-end ping.
        if !cfg.canonEnabled {
            return Response(status: .noContent)
        }

        // Build the candidate pool for this context.
        let candidates = canonCandidates(for: requestedContext, expletives: cfg.expletivesEnabled)
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
    /// When `expletives` is true the potty pool is used; otherwise the polite pool.
    nonisolated private static func canonCandidates(for context: String, expletives: Bool) -> [String] {
        guard let lists = canonContexts[context] else { return [] }
        return expletives ? lists.potty : lists.polite
    }

    /// Polite-mode swear scrub. Replaces known expletives with clean equivalents
    /// so Polite mode is authoritative even if a bespoke /speak line contains
    /// swears. Word-boundary aware (handles apostrophe forms like "fuckin’"),
    /// preserves first-letter case, and tidies whitespace a dropped intensifier
    /// leaves behind. Applied to bespoke /speak text ONLY when Polite is active.
    nonisolated static func politeScrub(_ input: String) -> String {
        let rules: [(String, String)] = [
            ("motherfuck\\w*", "blunder"),
            ("fuck(?:ing|in[‘’]?)", ""),
            ("fucked", "broke"),
            ("fuck\\w*", "blast"),
            ("dogshit", "dreadful"),
            ("bullshit", "nonsense"),
            ("shitshow", "shambles"),
            ("shitty", "dreadful"),
            ("shites?", "rubbish"),
            ("shit\\w*", "rubbish"),
            ("bastards", "blighters"),
            ("bastard", "blighter"),
            ("bollocks", "nonsense"),
            ("bloody", ""),
            ("buggered", "broken"),
            ("buggers", "blighters"),
            ("bugger", "blighter"),
            ("arseholes?", "blighter"),
            ("arse", "backside"),
            ("pissed", "annoyed"),
            ("piss\\w*", "fuss"),
            ("crap\\w*", "rubbish"),
            ("goddamn\\w*", "blasted"),
            ("damn(?:ed|it)?", "blasted"),
            ("twats?", "fool"),
            ("wankers?", "fool"),
            ("tossers?", "fool"),
        ]
        var s = input
        for (core, replacement) in rules {
            let pattern = "(?i)(?<![\\p{L}’])(?:\(core))(?![\\p{L}])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = s as NSString
            let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            for m in matches.reversed() {
                let matched = ns.substring(with: m.range)
                var rep = replacement
                if let first = matched.first, first.isUppercase, !rep.isEmpty {
                    rep = rep.prefix(1).uppercased() + rep.dropFirst()
                }
                s = (s as NSString).replacingCharacters(in: m.range, with: rep)
            }
        }
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first.isLowercase {
            s = s.prefix(1).uppercased() + s.dropFirst()
        }
        return s
    }

    // MARK: - Icon-state broadcast (targeted, change-only)

    /// Last muted state we broadcast as an `icon-state` event. A muted `/speak`
    /// must tell connected UIs the mute state (so the menu-bar glyph doesn't go
    /// stale), but re-broadcasting the full `/settings` blob on every muted call
    /// risks an echo-storm. Instead we emit a tiny `{"type":"icon-state",
    /// "muted":<bool>}` event, and ONLY when the state actually changed since the
    /// last one we sent — at most one event per real transition. `nil` = never
    /// broadcast yet, so the first observation always emits. Guarded by
    /// `iconStateLock` (this path is `nonisolated static`).
    nonisolated(unsafe) private static var lastBroadcastMuted: Bool?
    nonisolated private static let iconStateLock = NSLock()

    /// Broadcast a lightweight `icon-state` event iff `muted` differs from the
    /// last one we sent. Returns without broadcasting when unchanged.
    nonisolated private static func broadcastIconStateIfChanged(
        muted: Bool,
        sseBroadcaster: SSEBroadcaster
    ) async {
        let changed = iconStateLock.withLock { () -> Bool in
            guard lastBroadcastMuted != muted else { return false }
            lastBroadcastMuted = muted
            return true
        }
        guard changed else { return }
        // Payload carries `type` too (not just the SSE `event:` field) so a
        // client that switches on a parsed `data.type` still routes it.
        await sseBroadcaster.broadcast(
            event: "icon-state",
            json: "{\"type\":\"icon-state\",\"muted\":\(muted)}"
        )
    }

    // MARK: - /speak handler

    nonisolated private static func handleSpeak(
        request: Request,
        audioQueue: AudioQueueActor,
        sseBroadcaster: SSEBroadcaster,
        sessionRegistry: SessionRegistry
    ) async throws -> Response {

        // Parse body
        guard let bodyData = try? await request.body.collect(upTo: 1024 * 1024) else {
            return try Self.json(ErrorResponse("Invalid request body"), status: .badRequest)
        }
        guard let body = try? JSONSerialization.jsonObject(with: Data(buffer: bodyData)) as? [String: Any] else {
            return try Self.json(ErrorResponse("Invalid JSON"), status: .badRequest)
        }

        // Validate text
        guard var text = body["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return try Self.json(ErrorResponse("No text provided"), status: .badRequest)
        }
        let maxLen = 5000
        guard text.count <= maxLen else {
            return try Self.json(ErrorResponse("Text too long (max \(maxLen) chars)"), status: .badRequest)
        }

        // Hard mute — return 200 with muted flag; caller won't retry. Also tell
        // connected UIs the mute state so the menu-bar glyph doesn't go stale —
        // but only as a tiny `icon-state` event, and only when the state changed
        // (no echo-storm on a burst of muted calls).
        let cfg = PulsarConfig.shared
        if cfg.isMuted {
            await Self.broadcastIconStateIfChanged(muted: true, sseBroadcaster: sseBroadcaster)
            return try Self.json(MutedResponse(muted: true, text_preview: String(text.prefix(100))))
        }
        // Not muted on this call — if we last told clients "muted", correct it now
        // (state transitioned false) so a stale muted glyph clears via /speak too.
        await Self.broadcastIconStateIfChanged(muted: false, sseBroadcaster: sseBroadcaster)

        // Polite mode: scrub expletives from bespoke lines before they are
        // cached or spoken. The toggle is authoritative — Polite is always clean
        // regardless of what the caller sends. Canon lines are never scrubbed
        // (they are already pre-cleaned in the polite pool).
        if !cfg.expletivesEnabled {
            text = Self.politeScrub(text)
        }

        let channel  = body["channel"]  as? String
        let priority = body["priority"] as? Bool ?? false
        // Optional drone attribution. A drone category (e.g. "voyager") makes
        // that sibling drone the active speaker for this line; nil/"pulsar"
        // keeps the main Pulsar head speaking.
        let agentCategory = (body["agent"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }
        // The speaking sub-agent's session, from say.sh (CLAUDE_CODE_SESSION_ID).
        // Session-scopes the claim-on-speak promotion below. Absent → nil, and
        // promotion falls back to the old cross-session behaviour.
        let speakSessionId = (body["session_id"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }
        // Claim-on-speak: a sub-agent reveals its true character only by speaking
        // with `--agent X`, because the SubagentStart hook carries no task text and
        // registers every generic worker as an atlas. So when a tagged line comes
        // in, promote ONE generic in-flight drone's PRESENCE to this category and
        // re-broadcast the drone set — the swarm re-renders the real character
        // instead of a wall of identical atlases. If the actor actually promoted a
        // drone (or one already had this category) it returns true; only then does
        // the presence differ from the last broadcast, so we re-broadcast.
        if let agentCategory {
            let didPromote = await audioQueue.promoteInFlightDrone(
                toCategory: agentCategory, sessionId: speakSessionId)
            if didPromote {
                let drones = await audioQueue.inFlightDronesSnapshot()
                await Self.broadcastDrones(drones, sseBroadcaster: sseBroadcaster)
            }
        }
        // NOTE: a tagged `/speak` line no longer refreshes drone `lastSeen`. The
        // old category-wide touch kept a ghost drone (lost SubagentStop) immortal
        // beside any live same-category sibling. Liveness now rests on a reliable
        // SubagentStop + the shorter `droneStaleAfter` backstop sweep only.

        // A spoken line means this session is actively working. Track it (phase
        // "working"; window NOT moved — only a real user message does that) so the
        // Missions board reflects live work and re-broadcast the sessions payload.
        if let speakSessionId {
            await sessionRegistry.note(sessionId: speakSessionId, cwd: nil, phase: "working")
            await Self.broadcastSessions(
                sessionRegistry: sessionRegistry, audioQueue: audioQueue,
                sseBroadcaster: sseBroadcaster)
        }

        // macOS local voice — synthesise via `say` to a temp AIFF so it plays
        // through the same envelope/lip-sync path. No network, no API key, no
        // spend. (ElevenLabs removed.)
        let entryId = Self.nextEntryId()
        let entry = AudioEntry(
            id: entryId, text: String(text.prefix(100)), voiceId: "native",
            voiceLabel: "Pulsar", createdAt: Date(), channel: channel,
            priority: priority, fullText: text, isReplay: false,
            audioURL: nil, engine: "native", agentCategory: agentCategory)
        guard let position = await audioQueue.enqueue(entry) else {
            return try Self.json(SpeakResponse(
                id: entryId, position: nil, voice: "native",
                text_preview: String(text.prefix(100)), dropped: true, reason: "busy"))
        }
        let idCopy = entryId
        let textCopy = text
        let agentCopy = agentCategory
        Task.detached {
            do {
                let url = try await NativeVoiceClient.synth(text: textCopy, agent: agentCopy)
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
        let config = PulsarConfig.shared
        return SettingsResponse(
            muted: config.isMuted,
            expletives_enabled: config.expletivesEnabled,
            native_voice: NativeVoiceClient.bestVoice(),
            enhanced_installed: NativeVoiceClient.enhancedInstalled(),
            canon_enabled: config.canonEnabled,
            floating_head_enabled: config.floatingHeadEnabled,
            subtitles_enabled: config.subtitlesEnabled,
            show_active_agents: config.showActiveAgents,
            task_mode_enabled: config.taskModeEnabled,
            llm_titles_enabled: config.llmTitlesEnabled,
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

private struct DronesInFlightPayload: Encodable, Sendable {
    let drones: [String: String]
}

// MARK: - Session grouping wire models
//
// snake_case field names ARE the wire shape (no CodingKeys needed) — the app's
// DTO decodes exactly these keys.
private struct SessionsPayload: Encodable, Sendable {
    let sessions: [SessionPayload]
}

private struct SessionPayload: Encodable, Sendable {
    let session_id: String
    let name: String
    let label: String
    let phase: String
    let last_seen: Int
    let branch: String
    let repo: String
    let last_action: String
    let user_named: Bool
    /// The REAL Claude Desktop sidebar title, resolved locally (empty when none).
    let sidebar_title: String
    let drones: [SessionDronePayload]
}

private struct SessionDronePayload: Encodable, Sendable {
    let agent_id: String
    let category: String
}

private struct OkResponse: Encodable, Sendable {
    let ok: Bool
}

private struct SubagentResponse: Encodable, Sendable {
    let ok: Bool
    let drones: [String: String]
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
    let expletives_enabled: Bool
    let native_voice: String
    let enhanced_installed: Bool
    let canon_enabled: Bool
    let floating_head_enabled: Bool
    let subtitles_enabled: Bool
    let show_active_agents: Bool
    let task_mode_enabled: Bool
    let llm_titles_enabled: Bool
    let available_voices: [NativeVoiceClient.VoiceOption]
}

private struct SettingsUpdateRequest: Decodable, Sendable {
    let muted: Bool?
    let expletives_enabled: Bool?
    let canon_enabled: Bool?
    let floating_head_enabled: Bool?
    let subtitles_enabled: Bool?
    let show_active_agents: Bool?
    let task_mode_enabled: Bool?
    let llm_titles_enabled: Bool?
    let native_voice: String?
}
