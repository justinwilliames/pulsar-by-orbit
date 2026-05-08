import Foundation

struct CachedPhrase: Codable, Identifiable, Hashable {
    let key: String
    let text: String
    let voiceId: String
    let voiceLabel: String
    let firstCachedAt: Double
    let lastPlayedAt: Double?
    let playCount: Int
    let charCount: Int
    let sizeBytes: Int

    var id: String { key }
    var firstCachedDate: Date { Date(timeIntervalSince1970: firstCachedAt) }
    var lastPlayedDate: Date? { lastPlayedAt.map { Date(timeIntervalSince1970: $0) } }
    var isLegacy: Bool { text.isEmpty }

    enum CodingKeys: String, CodingKey {
        case key
        case text
        case voiceId = "voice_id"
        case voiceLabel = "voice_label"
        case firstCachedAt = "first_cached_at"
        case lastPlayedAt = "last_played_at"
        case playCount = "play_count"
        case charCount = "char_count"
        case sizeBytes = "size_bytes"
    }
}

struct CachedPhrasesResponse: Codable {
    let phrases: [CachedPhrase]
    let total: Int
    let totalSizeBytes: Int
    let maxBytes: Int

    enum CodingKeys: String, CodingKey {
        case phrases
        case total
        case totalSizeBytes = "total_size_bytes"
        case maxBytes = "max_bytes"
    }
}
