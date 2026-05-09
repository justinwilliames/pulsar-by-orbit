import Foundation
import Hummingbird

/// Local HTTP server hosted inside Caldwell.app. Exposes the same surface
/// that the Python daemon currently does so `say.sh`, the Stop hook, and
/// any external scripts keep working unchanged once the daemon is retired.
///
/// During the Python → Swift migration this runs alongside the daemon on
/// a separate port (7866). The endpoints get ported over phase-by-phase;
/// when parity is reached the LaunchAgent flips to point at the app and
/// the daemon directory is deleted.
///
/// Phase 1 (current): scaffold + /health endpoint only. Subsequent phases
/// port /speak, /queue, /history, /cache/*, /settings, /usage, /events,
/// /portraits/*.
final class CaldwellHTTPServer: @unchecked Sendable {

    /// During migration: 7866 to coexist with the Python daemon's 7865.
    /// Phase 5 flips this to 7865 and retires the Python daemon.
    static let migrationPort: Int = 7866

    private var serverTask: Task<Void, Error>?
    private let port: Int

    init(port: Int = CaldwellHTTPServer.migrationPort) {
        self.port = port
    }

    func start() {
        guard serverTask == nil else {
            NSLog("[CaldwellHTTP] start() called while server already running — ignoring")
            return
        }

        let port = self.port
        serverTask = Task.detached(priority: .userInitiated) {
            do {
                let router = Router()
                Self.registerRoutes(on: router)

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

    nonisolated private static func registerRoutes(on router: Router<BasicRequestContext>) {
        router.get("/health") { _, _ -> Response in
            // Same shape as the Python daemon's /health for parity.
            // queue_size is a placeholder until Phase 2 ports the queue.
            // `source` field added during migration so health checks can
            // identify which implementation is responding.
            let body = HealthResponse(
                status: "ok",
                version: "swift-2.0",
                queue_size: 0,
                source: "swift"
            )
            return try Self.json(body)
        }
    }

    // MARK: - Helpers

    nonisolated private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    nonisolated private static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try encoder.encode(value)
        let response = Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
        )
        return response
    }
}

// MARK: - Response Models

/// Mirrors the Python daemon's /health response shape.
private struct HealthResponse: Encodable, Sendable {
    let status: String
    let version: String
    let queue_size: Int
    let source: String
}
