import Foundation

struct QueueItem: Codable, Identifiable {
    let id: String
    let position: Int
    let status: String
    let voice: String
    let text: String
    let channel: String?
    let priority: Bool
    /// Drone category for the line (nil = Pulsar) — drives the pending thumbnail's
    /// face, since `voice` is a hardcoded "Pulsar" label.
    let agent: String?

    var isPlaying: Bool { status == "playing" }
}
