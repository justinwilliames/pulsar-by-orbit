import Foundation

struct DaemonSettings: Codable, Sendable {
    let muted: Bool?
    /// Whether Potty Mouth mode is on (true) or Polite (false, default).
    let expletivesEnabled: Bool?
    /// The macOS voice the native path resolves to (e.g. "Daniel (Enhanced)").
    let nativeVoice: String?
    /// Whether the neural Enhanced Daniel is installed (drives the install nudge).
    let enhancedInstalled: Bool?
    /// Whether cached "canon" pings are on (notification-style) vs bespoke-only.
    let canonEnabled: Bool?
    /// Whether the animated floating Pulsar head is shown on screen while it
    /// speaks. Default true.
    let floatingHeadEnabled: Bool?
    /// Whether the read-along caption bubble shows below the head. Default true.
    let subtitlesEnabled: Bool?
    /// Whether the orbiting/clustered sub-agent "drones" (the active-agent swarm)
    /// are shown. Default true; when false only Pulsar himself appears. Pulsar's
    /// own voice + head are unaffected.
    let showActiveAgents: Bool?
    /// Whether Task Mode is enabled — reveals the persistent Missions board tab.
    /// Default false (opt-in).
    let taskModeEnabled: Bool?
    /// Whether AI-generated mission titles are enabled. Default false — local
    /// first-line naming is canonical; the LLM title is a disclosed opt-in.
    let llmTitlesEnabled: Bool?
    /// Installed local voices usable in free mode (drives the voice picker),
    /// each with a "Name (Language, Region)" label.
    let availableVoices: [NativeVoiceClient.VoiceOption]?

    enum CodingKeys: String, CodingKey {
        case muted
        case expletivesEnabled = "expletives_enabled"
        case nativeVoice = "native_voice"
        case enhancedInstalled = "enhanced_installed"
        case canonEnabled = "canon_enabled"
        case floatingHeadEnabled = "floating_head_enabled"
        case subtitlesEnabled = "subtitles_enabled"
        case showActiveAgents = "show_active_agents"
        case taskModeEnabled = "task_mode_enabled"
        case llmTitlesEnabled = "llm_titles_enabled"
        case availableVoices = "available_voices"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        self.expletivesEnabled = try container.decodeIfPresent(Bool.self, forKey: .expletivesEnabled)
        self.nativeVoice = try container.decodeIfPresent(String.self, forKey: .nativeVoice)
        self.enhancedInstalled = try container.decodeIfPresent(Bool.self, forKey: .enhancedInstalled)
        self.canonEnabled = try container.decodeIfPresent(Bool.self, forKey: .canonEnabled)
        self.floatingHeadEnabled = try container.decodeIfPresent(Bool.self, forKey: .floatingHeadEnabled)
        self.subtitlesEnabled = try container.decodeIfPresent(Bool.self, forKey: .subtitlesEnabled)
        self.showActiveAgents = try container.decodeIfPresent(Bool.self, forKey: .showActiveAgents)
        self.taskModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .taskModeEnabled)
        self.llmTitlesEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmTitlesEnabled)
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
