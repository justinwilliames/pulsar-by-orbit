import Foundation

struct DaemonSettings: Codable, Sendable {
    let apiKeySet: Bool
    let apiKeyPreview: String
    let voiceId: String
    let voiceLabel: String
    let expletivesEnabled: Bool?
    let muted: Bool?

    enum CodingKeys: String, CodingKey {
        case apiKeySet = "api_key_set"
        case apiKeyPreview = "api_key_preview"
        case voiceId = "voice_id"
        case voiceLabel = "voice_label"
        case expletivesEnabled = "expletives_enabled"
        case muted
    }
}

struct DaemonUsage: Codable, Sendable {
    let minuteCalls: Int
    let minuteLimit: Int
    let dailyChars: Int
    let dailyCap: Int
    let dailyDate: String
    let limitsActive: Bool
    let elevenlabs: ElevenLabsUsage?

    enum CodingKeys: String, CodingKey {
        case minuteCalls = "minute_calls"
        case minuteLimit = "minute_limit"
        case dailyChars = "daily_chars"
        case dailyCap = "daily_cap"
        case dailyDate = "daily_date"
        case limitsActive = "limits_active"
        case elevenlabs
    }
}

struct ElevenLabsUsage: Codable, Sendable {
    let tier: String
    let characterCount: Int
    let characterLimit: Int
    let nextResetUnix: Int
    let periodStartUnix: Int?
    let createdAtUnix: Int?
    let billingPeriod: String?
    let periodDays: Double?
    let fetchedAt: Double
    let percentUsed: Double
    let daysUntilReset: Double
    let daysElapsed: Double?
    let expectedUsagePct: Double
    let runRateRatio: Double
    let runRateStatus: String

    enum CodingKeys: String, CodingKey {
        case tier
        case characterCount = "character_count"
        case characterLimit = "character_limit"
        case nextResetUnix = "next_reset_unix"
        case periodStartUnix = "period_start_unix"
        case createdAtUnix = "created_at_unix"
        case billingPeriod = "billing_period"
        case periodDays = "period_days"
        case fetchedAt = "fetched_at"
        case percentUsed = "percent_used"
        case daysUntilReset = "days_until_reset"
        case daysElapsed = "days_elapsed"
        case expectedUsagePct = "expected_usage_pct"
        case runRateRatio = "run_rate_ratio"
        case runRateStatus = "run_rate_status"
    }

    enum Status: String {
        case ok, watch, warning, critical, exhausted, unknown
    }

    var status: Status {
        Status(rawValue: runRateStatus) ?? .unknown
    }

    var tierDisplay: String {
        tier.prefix(1).uppercased() + tier.dropFirst().lowercased()
    }

    var periodStartDate: Date? {
        guard let unix = periodStartUnix, unix > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    var nextResetDate: Date {
        Date(timeIntervalSince1970: TimeInterval(nextResetUnix))
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
    let muted: Bool?
    let error: String?
    let field: String?

    enum CodingKeys: String, CodingKey {
        case saved
        case apiKeySet = "api_key_set"
        case apiKeyPreview = "api_key_preview"
        case voiceId = "voice_id"
        case voiceMeta = "voice_meta"
        case expletivesEnabled = "expletives_enabled"
        case muted
        case error
        case field
    }
}
