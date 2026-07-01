import Foundation

actor SSEBroadcaster: SSEBroadcasterProtocol {
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    func makeStream() -> AsyncStream<String> {
        let id = UUID()
        // Bound the per-client buffer. The default `.unbounded` policy lets a
        // stalled / slow `/events` reader accumulate EVERY broadcast event
        // forever — an unbounded memory leak per hung client. `.bufferingNewest`
        // caps it: once 64 events back up, the oldest are dropped so the newest
        // state still arrives. SSE here carries live UI state (voice_active,
        // drones_in_flight, settings) where the freshest event supersedes stale
        // ones, so dropping the oldest under backpressure is the correct trade.
        return AsyncStream<String>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [id] _ in
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
    }

    func broadcast(event: String, json: String) async {
        let payload = "event: \(event)\ndata: \(json)\n\n"
        for continuation in continuations.values {
            continuation.yield(payload)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
