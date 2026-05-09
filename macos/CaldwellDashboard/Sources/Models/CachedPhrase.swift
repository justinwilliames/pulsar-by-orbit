import Foundation

struct CachedPhrase: Decodable, Identifiable, Hashable {
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
        case createdAt = "created_at"
        case firstCachedAt = "first_cached_at"
        case lastPlayedAt = "last_played_at"
        case playCount = "play_count"
        case charCount = "char_count"
        case sizeBytes = "size_bytes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.voiceId = try container.decodeIfPresent(String.self, forKey: .voiceId) ?? ""
        self.voiceLabel = try container.decodeIfPresent(String.self, forKey: .voiceLabel) ?? self.voiceId
        let createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
        let firstCachedAt = try container.decodeIfPresent(Double.self, forKey: .firstCachedAt)
        self.firstCachedAt = createdAt ?? firstCachedAt ?? 0
        self.lastPlayedAt = try container.decodeIfPresent(Double.self, forKey: .lastPlayedAt)
        self.playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        self.charCount = try container.decodeIfPresent(Int.self, forKey: .charCount) ?? 0
        self.sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
    }
}

struct CachedPhrasesResponse: Decodable {
    let phrases: [CachedPhrase]
    let total: Int
    let totalSizeBytes: Int
    let maxBytes: Int

    enum CodingKeys: String, CodingKey {
        case phrases
        case total
        case count
        case totalBytes = "total_bytes"
        case totalSizeBytes = "total_size_bytes"
        case maxBytes = "max_bytes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.phrases = try container.decode([CachedPhrase].self, forKey: .phrases)
        self.total = try container.decodeIfPresent(Int.self, forKey: .total)
            ?? container.decodeIfPresent(Int.self, forKey: .count)
            ?? phrases.count
        self.totalSizeBytes = try container.decodeIfPresent(Int.self, forKey: .totalSizeBytes)
            ?? container.decodeIfPresent(Int.self, forKey: .totalBytes)
            ?? 0
        self.maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 0
    }
}
