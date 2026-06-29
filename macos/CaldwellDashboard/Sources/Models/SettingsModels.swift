import Foundation

struct DaemonSettings: Codable, Sendable {
    let muted: Bool?
    /// The macOS voice the native path resolves to (e.g. "Daniel (Enhanced)").
    let nativeVoice: String?
    /// Whether the neural Enhanced Daniel is installed (drives the install nudge).
    let enhancedInstalled: Bool?
    /// Whether cached "canon" pings are on (notification-style) vs bespoke-only.
    let canonEnabled: Bool?
    /// Installed local voices usable in free mode (drives the voice picker),
    /// each with a "Name (Language, Region)" label.
    let availableVoices: [NativeVoiceClient.VoiceOption]?

    enum CodingKeys: String, CodingKey {
        case muted
        case nativeVoice = "native_voice"
        case enhancedInstalled = "enhanced_installed"
        case canonEnabled = "canon_enabled"
        case availableVoices = "available_voices"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        self.nativeVoice = try container.decodeIfPresent(String.self, forKey: .nativeVoice)
        self.enhancedInstalled = try container.decodeIfPresent(Bool.self, forKey: .enhancedInstalled)
        self.canonEnabled = try container.decodeIfPresent(Bool.self, forKey: .canonEnabled)
        self.availableVoices = try container.decodeIfPresent([NativeVoiceClient.VoiceOption].self, forKey: .availableVoices)
    }
}

struct SettingsSaveResponse: Codable, Sendable {
    let saved: Bool?
    let muted: Bool?
    let error: String?
    let field: String?

    enum CodingKeys: String, CodingKey {
        case saved
        case muted
        case error
        case field
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.field = try container.decodeIfPresent(String.self, forKey: .field)

        let hasSettingsPayload = muted != nil
        self.saved = try container.decodeIfPresent(Bool.self, forKey: .saved)
            ?? (error == nil && hasSettingsPayload ? true : nil)
    }
}
