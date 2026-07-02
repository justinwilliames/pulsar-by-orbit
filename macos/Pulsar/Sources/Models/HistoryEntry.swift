import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: String
    let voice: String
    let text: String
    let channel: String?
    let timestamp: Double
    let duration: Double?
    let type: String
    let failed: Bool

    var date: Date { Date(timeIntervalSince1970: timestamp) }

    enum CodingKeys: String, CodingKey {
        case id
        case voice
        case text
        case channel
        case timestamp
        case duration
        case type
        case failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.voice = try container.decode(String.self, forKey: .voice)
        self.text = try container.decode(String.self, forKey: .text)
        self.channel = try container.decodeIfPresent(String.self, forKey: .channel)
        self.timestamp = try container.decode(Double.self, forKey: .timestamp)
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "speak"
        self.failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }
}
