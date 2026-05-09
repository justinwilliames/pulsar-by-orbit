import Foundation

actor SSEBroadcaster: SSEBroadcasterProtocol {
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    func makeStream() -> AsyncStream<String> {
        let id = UUID()
        return AsyncStream<String> { continuation in
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
