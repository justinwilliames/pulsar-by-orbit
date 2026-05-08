import Foundation

struct DaemonSettings: Codable, Sendable {
    let apiKeySet: Bool
    let apiKeyPreview: String
    let voiceId: String
    let voiceLabel: String
    let expletivesEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case apiKeySet = "api_key_set"
        case apiKeyPreview = "api_key_preview"
        case voiceId = "voice_id"
        case voiceLabel = "voice_label"
        case expletivesEnabled = "expletives_enabled"
    }
}

struct DaemonUsage: Codable, Sendable {
    let minuteCalls: Int
    let minuteLimit: Int
    let dailyChars: Int
    let dailyCap: Int
    let dailyDate: String
    let limitsActive: Bool

    enum CodingKeys: String, CodingKey {
        case minuteCalls = "minute_calls"
        case minuteLimit = "minute_limit"
        case dailyChars = "daily_chars"
        case dailyCap = "daily_cap"
        case dailyDate = "daily_date"
        case limitsActive = "limits_active"
    }
}

struct VoiceMetadata: Codable, Sendable {
    let name: String?
    let category: String?
}

struct SettingsSaveResponse: Codable, Sendable {
    let saved: Bool?
    let apiKeySet: Bool?
    let apiKeyPreview: String?
    let voiceId: String?
    let voiceMeta: VoiceMetadata?
    let expletivesEnabled: Bool?
    let error: String?
    let field: String?

    enum CodingKeys: String, CodingKey {
        case saved
        case apiKeySet = "api_key_set"
        case apiKeyPreview = "api_key_preview"
        case voiceId = "voice_id"
        case voiceMeta = "voice_meta"
        case expletivesEnabled = "expletives_enabled"
        case error
        case field
    }
}
