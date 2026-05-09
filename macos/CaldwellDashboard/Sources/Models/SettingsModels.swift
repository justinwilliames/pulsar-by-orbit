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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.apiKeySet = try container.decodeIfPresent(Bool.self, forKey: .apiKeySet) ?? false
        self.apiKeyPreview = try container.decodeIfPresent(String.self, forKey: .apiKeyPreview) ?? ""
        self.voiceId = try container.decodeIfPresent(String.self, forKey: .voiceId) ?? ""
        self.voiceLabel = try container.decodeIfPresent(String.self, forKey: .voiceLabel) ?? self.voiceId
        self.expletivesEnabled = try container.decodeIfPresent(Bool.self, forKey: .expletivesEnabled)
        self.muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
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
    let apiKeySet: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case minuteCalls = "minute_calls"
        case minuteLimit = "minute_limit"
        case dailyChars = "daily_chars"
        case dailyCap = "daily_cap"
        case dailyDate = "daily_date"
        case limitsActive = "limits_active"
        case elevenlabs
    }

    enum CompactCodingKeys: String, CodingKey {
        case charactersUsed = "characters_used"
        case charactersLimit = "characters_limit"
        case nextResetUnix = "next_reset_unix"
        case apiKeySet = "api_key_set"
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let compact = try decoder.container(keyedBy: CompactCodingKeys.self)

        self.minuteCalls = try container.decodeIfPresent(Int.self, forKey: .minuteCalls) ?? 0
        self.minuteLimit = try container.decodeIfPresent(Int.self, forKey: .minuteLimit) ?? 0
        self.dailyChars = try container.decodeIfPresent(Int.self, forKey: .dailyChars) ?? 0
        self.dailyCap = try container.decodeIfPresent(Int.self, forKey: .dailyCap) ?? 0
        self.dailyDate = try container.decodeIfPresent(String.self, forKey: .dailyDate) ?? ""
        self.limitsActive = try container.decodeIfPresent(Bool.self, forKey: .limitsActive) ?? false
        self.apiKeySet = try compact.decodeIfPresent(Bool.self, forKey: .apiKeySet)
        self.error = try compact.decodeIfPresent(String.self, forKey: .error)

        if let elevenlabs = try container.decodeIfPresent(ElevenLabsUsage.self, forKey: .elevenlabs) {
            self.elevenlabs = elevenlabs
        } else if let charactersUsed = try compact.decodeIfPresent(Int.self, forKey: .charactersUsed),
                  let charactersLimit = try compact.decodeIfPresent(Int.self, forKey: .charactersLimit),
                  let nextResetUnix = try compact.decodeIfPresent(Int.self, forKey: .nextResetUnix) {
            self.elevenlabs = ElevenLabsUsage(
                compactCharacterCount: charactersUsed,
                characterLimit: charactersLimit,
                nextResetUnix: nextResetUnix
            )
        } else {
            self.elevenlabs = nil
        }
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? "Unknown"
        self.characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount) ?? 0
        self.characterLimit = try container.decodeIfPresent(Int.self, forKey: .characterLimit) ?? 0
        self.nextResetUnix = try container.decodeIfPresent(Int.self, forKey: .nextResetUnix) ?? 0
        self.periodStartUnix = try container.decodeIfPresent(Int.self, forKey: .periodStartUnix)
        self.createdAtUnix = try container.decodeIfPresent(Int.self, forKey: .createdAtUnix)
        self.billingPeriod = try container.decodeIfPresent(String.self, forKey: .billingPeriod)
        self.periodDays = try container.decodeIfPresent(Double.self, forKey: .periodDays)
        self.fetchedAt = try container.decodeIfPresent(Double.self, forKey: .fetchedAt) ?? Date().timeIntervalSince1970

        let fallbackPercentUsed: Double
        if self.characterLimit > 0 {
            fallbackPercentUsed = (Double(self.characterCount) / Double(self.characterLimit)) * 100
        } else {
            fallbackPercentUsed = 0
        }
        self.percentUsed = try container.decodeIfPresent(Double.self, forKey: .percentUsed) ?? fallbackPercentUsed
        self.daysUntilReset = try container.decodeIfPresent(Double.self, forKey: .daysUntilReset)
            ?? max(0, (Double(self.nextResetUnix) - Date().timeIntervalSince1970) / 86_400)
        self.daysElapsed = try container.decodeIfPresent(Double.self, forKey: .daysElapsed)
        self.expectedUsagePct = try container.decodeIfPresent(Double.self, forKey: .expectedUsagePct) ?? self.percentUsed
        self.runRateRatio = try container.decodeIfPresent(Double.self, forKey: .runRateRatio) ?? 1
        self.runRateStatus = try container.decodeIfPresent(String.self, forKey: .runRateStatus)
            ?? (self.characterLimit > 0 && self.characterCount >= self.characterLimit ? "exhausted" : "unknown")
    }

    init(compactCharacterCount: Int, characterLimit: Int, nextResetUnix: Int) {
        self.tier = "Unknown"
        self.characterCount = compactCharacterCount
        self.characterLimit = characterLimit
        self.nextResetUnix = nextResetUnix
        self.periodStartUnix = nil
        self.createdAtUnix = nil
        self.billingPeriod = nil
        self.periodDays = nil
        self.fetchedAt = Date().timeIntervalSince1970
        if characterLimit > 0 {
            self.percentUsed = (Double(compactCharacterCount) / Double(characterLimit)) * 100
        } else {
            self.percentUsed = 0
        }
        self.daysUntilReset = max(0, (Double(nextResetUnix) - Date().timeIntervalSince1970) / 86_400)
        self.daysElapsed = nil
        self.expectedUsagePct = self.percentUsed
        self.runRateRatio = 1
        self.runRateStatus = characterLimit > 0 && compactCharacterCount >= characterLimit ? "exhausted" : "unknown"
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.apiKeySet = try container.decodeIfPresent(Bool.self, forKey: .apiKeySet)
        self.apiKeyPreview = try container.decodeIfPresent(String.self, forKey: .apiKeyPreview)
        self.voiceId = try container.decodeIfPresent(String.self, forKey: .voiceId)
        self.voiceMeta = try container.decodeIfPresent(VoiceMetadata.self, forKey: .voiceMeta)
        self.expletivesEnabled = try container.decodeIfPresent(Bool.self, forKey: .expletivesEnabled)
        self.muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.field = try container.decodeIfPresent(String.self, forKey: .field)

        let hasSettingsPayload = apiKeySet != nil ||
            apiKeyPreview != nil ||
            voiceId != nil ||
            expletivesEnabled != nil ||
            muted != nil
        self.saved = try container.decodeIfPresent(Bool.self, forKey: .saved)
            ?? (error == nil && hasSettingsPayload ? true : nil)
    }
}
