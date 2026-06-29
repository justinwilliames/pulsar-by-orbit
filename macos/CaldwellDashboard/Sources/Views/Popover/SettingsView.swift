import AppKit
import Sparkle
import SwiftUI

struct SettingsView: View {
    let viewModel: DashboardViewModel
    let updater: SPUUpdater

    @State private var apiKey: String = ""
    @State private var voiceId: String = ""
    @State private var apiKeyTouched: Bool = false
    @State private var voiceIdTouched: Bool = false
    @State private var useCustomVoiceId: Bool = false
    @State private var saving: Bool = false
    @State private var statusMessage: String?
    @State private var statusKind: StatusKind = .info
    @State private var showingApiKey: Bool = false
    @State private var personaSaving: Bool = false
    @State private var engineSaving: Bool = false

    enum StatusKind { case ok, error, info }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                recoveryBanners
                personaSection
                Divider()
                voiceSection
                statusBanner
                Divider()
                usageSection
                Divider()
                CheckForUpdatesView(updater: updater)
            }
            .padding(16)
        }
        .task {
            await viewModel.loadSettings()
            await viewModel.loadUsage()
            // Sync local fields once after load
            if !voiceIdTouched, let id = viewModel.settings?.voiceId {
                voiceId = id
                // Default to Custom mode if the stored ID isn't one of the
                // known premades — so Sir's cloned/library voices show in
                // the manual field instead of being silently snapped to a
                // preset by the Picker.
                useCustomVoiceId = !Self.premadeVoices.contains(where: { $0.id == id })
            }
        }
    }

    // MARK: - Persona Mode

    @ViewBuilder
    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CALDWELL'S MODE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            let mode = personaModeBinding
            Picker("Mode", selection: mode) {
                Text("Polite").tag(false)
                Text("Potty Mouth").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(personaSaving)

            HStack(spacing: 6) {
                if personaSaving {
                    ProgressView().scaleEffect(0.5)
                }
                Text(personaModeHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private var personaModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings?.expletivesEnabled ?? true },
            set: { newValue in
                Task { await savePersona(expletivesEnabled: newValue) }
            }
        )
    }

    private var personaModeHint: String {
        if viewModel.settings?.expletivesEnabled == false {
            return "Polite — butler-formal RP, no expletives, no rough language."
        }
        return "Potty Mouth — RP precision with unflinching expletives where the moment earns it."
    }

    private func savePersona(expletivesEnabled: Bool) async {
        personaSaving = true
        defer { personaSaving = false }
        let result = await viewModel.saveSettings(apiKey: nil, voiceId: nil, expletivesEnabled: expletivesEnabled)
        if case .failure(let error) = result {
            statusMessage = "Mode change failed: \(error)"
            statusKind = .error
        }
    }

    // MARK: - Voice (source + message style + install nudge + credentials)

    @ViewBuilder
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VOICE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            // The engine choice is a COST/PRIVACY decision, never named or framed
            // as quality — one Caldwell identity across both sources.
            Picker("Voice source", selection: voiceEngineBinding) {
                Text("Local & private (free)").tag("native")
                Text("Premium (uses credits)").tag("elevenlabs")
            }
            .pickerStyle(.menu)
            .disabled(engineSaving)

            Text(voiceEngineHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.settings?.voiceEngine == "native",
               let voices = viewModel.settings?.availableVoices, !voices.isEmpty {
                Picker("Local voice", selection: nativeVoiceBinding) {
                    ForEach(voices, id: \.name) { v in Text(v.label).tag(v.name) }
                }
                .pickerStyle(.menu)
                Text("Pick any installed voice. Download more under System Settings → Accessibility → Spoken Content. (Apple reserves the Siri voices for the system — they can't be used here.)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.settings?.enhancedInstalled == false {
                installNudge
            }

            Toggle(isOn: canonEnabledBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick cached pings")
                        .font(.caption.weight(.medium))
                    Text(canonHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    apiKeySection
                    voiceIdSection
                    saveButton
                }
                .padding(.top, 6)
            } label: {
                Text("PREMIUM VOICE CREDENTIALS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
        }
    }

    private var voiceEngineBinding: Binding<String> {
        Binding(
            get: { viewModel.settings?.voiceEngine ?? "elevenlabs" },
            set: { newValue in
                Task { engineSaving = true; await viewModel.setVoiceEngine(newValue); engineSaving = false }
            }
        )
    }

    private var nativeVoiceBinding: Binding<String> {
        Binding(
            get: { viewModel.settings?.nativeVoice ?? "Daniel" },
            set: { newValue in Task { await viewModel.setNativeVoice(newValue) } }
        )
    }

    private var voiceEngineHint: String {
        let native = viewModel.settings?.nativeVoice ?? "Daniel"
        if viewModel.settings?.voiceEngine == "native" {
            return "Speaks on your Mac (\(native)) — free, fully local, nothing leaves your machine."
        }
        return "Premium cloud voice — spends credits. Falls back to the free local voice automatically when credits run out."
    }

    private var canonEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings?.canonEnabled ?? true },
            set: { newValue in Task { await viewModel.setCanonEnabled(newValue) } }
        )
    }

    private var canonHint: String {
        if viewModel.settings?.canonEnabled == false {
            return "Off — bespoke only: richer, fewer lines (each costs credit on the premium voice)."
        }
        return "On — frequent short “Pushed, Sir.”-style pings at turn-end. Free."
    }

    @ViewBuilder
    private var installNudge: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tip: install Daniel (Enhanced) for a warmer local voice")
                .font(.caption2.weight(.medium))
            Text("System Settings → Accessibility → Spoken Content → System Voice → Manage Voices → English (UK). Until then Caldwell uses the basic Daniel.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Spoken Content settings") { openSpokenContentSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func openSpokenContentSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Recovery banners (every silent state gets a visible, actionable cue)

    @ViewBuilder
    private var recoveryBanners: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.settings?.muted == true {
                recoveryBanner(icon: "speaker.slash.fill",
                               text: "Caldwell is muted — no voice will play.",
                               actionLabel: "Unmute", tint: .secondary) {
                    Task { await viewModel.toggleMute() }
                }
            }
            if viewModel.settings?.voiceEngine != "native",
               viewModel.usage?.elevenlabs?.status == .exhausted {
                recoveryBanner(icon: "exclamationmark.triangle.fill",
                               text: "Premium credits exhausted — switch to the free local voice to keep Caldwell talking.",
                               actionLabel: "Switch to local", tint: .orange) {
                    Task { await viewModel.setVoiceEngine("native") }
                }
            }
            if viewModel.settings?.enhancedInstalled == false,
               viewModel.settings?.voiceEngine == "native" {
                recoveryBanner(icon: "arrow.down.circle",
                               text: "Using basic Daniel — install Daniel (Enhanced) for a warmer voice.",
                               actionLabel: "Install", tint: .blue) {
                    openSpokenContentSettings()
                }
            }
        }
    }

    private func recoveryBanner(icon: String, text: String, actionLabel: String,
                                tint: Color, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Button(actionLabel, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(8)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - API Key

    @ViewBuilder
    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ELEVENLABS API KEY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            HStack(spacing: 6) {
                Group {
                    if showingApiKey {
                        TextField("sk_...", text: $apiKey)
                    } else {
                        SecureField("sk_...", text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKey) { _, _ in apiKeyTouched = true }

                Button {
                    showingApiKey.toggle()
                } label: {
                    Image(systemName: showingApiKey ? "eye.slash" : "eye")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help(showingApiKey ? "Hide" : "Show")
            }

            Text(apiKeyHintText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    private var apiKeyHintText: String {
        if let s = viewModel.settings, s.apiKeySet {
            return "Stored in macOS Keychain. Current: \(s.apiKeyPreview). Leave blank to keep."
        }
        return "No key set. Stored in macOS Keychain on save."
    }

    // MARK: - Voice ID

    /// ElevenLabs premade (stock) voices. Universally available on every
    /// account tier — including free — via the API. Library/professional
    /// voices return HTTP 402 on free, so we surface only these in the
    /// picker. For paid-tier custom voices, Sir can flip to the manual
    /// Voice ID field via the toggle.
    private static let premadeVoices: [(id: String, name: String)] = [
        ("JBFqnCBsd6RMkjVDRZzb", "George — British, mature"),
        ("CwhRBWXzGAHq8TQ4Fs17", "Roger — laid-back, resonant"),
        ("nPczCjzI2devNBz1zQrb", "Brian — deep, calm"),
        ("onwK4e9ZLuTAKqWW03F9", "Daniel — authoritative British"),
        ("bIHbv24MWmeRgasZH58o", "Will — friendly American"),
        ("iP95p4xoKVk53GoZ742B", "Chris — casual American"),
        ("cjVigY5qzO86Huf0OWal", "Eric — smooth American"),
        ("N2lVS1w4EtoT3dr4eOWO", "Callum — gravelly British"),
        ("TX3LPaxmHKxFdv7VOQHJ", "Liam — articulate American"),
        ("IKne3meq5aSn9XLyUdCD", "Charlie — warm Australian"),
        ("pqHfZKP75CvOlQylNhV4", "Bill — older American"),
        ("hpp4J3VqNfWAUOO0d1Us", "Bella — bright, warm"),
        ("EXAVITQu4vr4xnSDxMaL", "Sarah — reassuring American"),
        ("FGY2WhTYpPnrIDTdsKH5", "Laura — quirky American"),
        ("XB0fDUnXU5powFXDhCwa", "Charlotte — sultry Swedish"),
        ("Xb7hH8MSUJpSbSDYk0k2", "Alice — confident British"),
        ("XrExE9yKIg1WjnnlVkGX", "Matilda — friendly American"),
        ("cgSgspJ2msm6clMCkdW9", "Jessica — expressive American"),
        ("pFZP5JQG7iQjIQuC4Bku", "Lily — warm British"),
    ]

    @ViewBuilder
    private var voiceIdSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("VOICE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Button(useCustomVoiceId ? "Use preset" : "Custom ID…") {
                    useCustomVoiceId.toggle()
                    voiceIdTouched = true
                    if !useCustomVoiceId {
                        // Switching back to presets: snap to closest premade
                        // (default to George if current value isn't a known preset).
                        if !Self.premadeVoices.contains(where: { $0.id == voiceId }) {
                            voiceId = Self.premadeVoices.first?.id ?? voiceId
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if useCustomVoiceId {
                TextField("20-character voice ID", text: $voiceId)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: voiceId) { _, _ in voiceIdTouched = true }

                Text("Paste any ElevenLabs voice ID. Library/professional voices need a paid plan — free tier rejects them with HTTP 402.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            } else {
                Picker("", selection: $voiceId) {
                    ForEach(Self.premadeVoices, id: \.id) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: voiceId) { _, _ in voiceIdTouched = true }

                Text("Premade voices — work on every tier including free. For your own cloned or library voices, switch to Custom ID.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - Save Button

    @ViewBuilder
    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            if saving {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Validating with ElevenLabs…")
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Save & validate")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(saving || (!apiKeyTouched && !voiceIdTouched))
    }

    // MARK: - Status Banner

    @ViewBuilder
    private var statusBanner: some View {
        if let msg = statusMessage {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: statusKind == .ok ? "checkmark.circle.fill"
                                : statusKind == .error ? "exclamationmark.triangle.fill"
                                : "info.circle.fill")
                Text(msg)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(statusBackground)
            .foregroundStyle(statusForeground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var statusBackground: Color {
        switch statusKind {
        case .ok: return .green.opacity(0.15)
        case .error: return .red.opacity(0.15)
        case .info: return .blue.opacity(0.10)
        }
    }

    private var statusForeground: Color {
        switch statusKind {
        case .ok: return .green
        case .error: return .red
        case .info: return .secondary
        }
    }

    // MARK: - Usage Section

    @ViewBuilder
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            elevenLabsSection
            dailyUsageSection
        }
    }

    @ViewBuilder
    private var elevenLabsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ELEVENLABS — MONTHLY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            if let eleven = viewModel.usage?.elevenlabs {
                HStack(alignment: .firstTextBaseline) {
                    Text(eleven.tierDisplay)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 0.5))
                    Spacer()
                    runRateBadge(eleven)
                }

                MonthlyUsageBar(
                    used: eleven.characterCount,
                    limit: eleven.characterLimit,
                    expectedPct: eleven.expectedUsagePct,
                    status: eleven.status
                )

                HStack {
                    Text(monthlySummary(eleven))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(resetCountdown(eleven))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(cycleRange(eleven))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                if let advice = runRateAdvice(eleven) {
                    Text(advice)
                        .font(.caption2)
                        .foregroundStyle(adviceColour(for: eleven.status))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(adviceColour(for: eleven.status).opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text("Loading subscription…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var dailyUsageSection: some View {
        // Local daemon caps — not pulled from ElevenLabs; these are
        // advisory ceilings the daemon enforces locally before touching
        // ElevenLabs at all. Collapsed by default; the live ElevenLabs
        // numbers above are the source of truth for actual usage.
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let usage = viewModel.usage {
                    if usage.dailyCap > 0 {
                        UsageBar(label: "Characters",
                                 current: usage.dailyChars,
                                 max: usage.dailyCap)
                    }
                    if usage.minuteLimit > 0 {
                        UsageBar(label: "Calls/min",
                                 current: usage.minuteCalls,
                                 max: usage.minuteLimit)
                    }
                    if !usage.limitsActive {
                        Text("Spend caps disabled.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text("Local advisory caps; reset at local midnight. The live ElevenLabs counter above is the source of truth for real usage.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Loading…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("LOCAL DAEMON CAPS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
        }
    }

    private func runRateBadge(_ eleven: ElevenLabsUsage) -> some View {
        let (label, colour) = runRateLabel(for: eleven.status)
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colour.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(colour.opacity(0.4), lineWidth: 0.5))
    }

    private func runRateLabel(for status: ElevenLabsUsage.Status) -> (String, Color) {
        switch status {
        case .ok:        return ("On pace", .green)
        case .watch:     return ("Watch", .yellow)
        case .warning:   return ("Warning", .orange)
        case .critical:  return ("Critical", .red)
        case .exhausted: return ("Exhausted", .red)
        case .unknown:   return ("—", .gray)
        }
    }

    private func adviceColour(for status: ElevenLabsUsage.Status) -> Color {
        switch status {
        case .ok:        return .green
        case .watch:     return .yellow
        case .warning:   return .orange
        case .critical:  return .red
        case .exhausted: return .red
        case .unknown:   return .gray
        }
    }

    private func monthlySummary(_ eleven: ElevenLabsUsage) -> String {
        let used = eleven.characterCount.formatted()
        let limit = eleven.characterLimit.formatted()
        return "\(used) / \(limit) chars · \(String(format: "%.0f", eleven.percentUsed))%"
    }

    private func resetCountdown(_ eleven: ElevenLabsUsage) -> String {
        let days = eleven.daysUntilReset
        if days < 1 {
            return "resets <1 day"
        }
        return "resets in \(Int(days)) day\(Int(days) == 1 ? "" : "s")"
    }

    private func cycleRange(_ eleven: ElevenLabsUsage) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let end = formatter.string(from: eleven.nextResetDate)
        if let start = eleven.periodStartDate {
            let startStr = formatter.string(from: start)
            let elapsed = eleven.daysElapsed.map { String(format: "%.1f", $0) } ?? "?"
            let total = eleven.periodDays.map { String(format: "%.1f", $0) } ?? "30"
            return "Cycle: \(startStr) → \(end) · day \(elapsed) of \(total)"
        }
        return "Resets \(end)"
    }

    private func runRateAdvice(_ eleven: ElevenLabsUsage) -> String? {
        switch eleven.status {
        case .ok:
            return nil
        case .watch:
            return String(format: "On track — currently using %.1f× expected pace. Worth keeping an eye on.", eleven.runRateRatio)
        case .warning:
            return String(format: "Trending high — %.1f× expected pace. At this rate the monthly tier exhausts before reset.", eleven.runRateRatio)
        case .critical:
            return String(format: "Heavy usage — %.1f× expected pace. Consider tightening the daemon's daily cap, leaning harder on cached canon, or upgrading the ElevenLabs tier.", eleven.runRateRatio)
        case .exhausted:
            return "Monthly allowance exhausted. New compositions will fail until reset; cached phrases still play free."
        case .unknown:
            return nil
        }
    }

    // MARK: - Save

    private func save() async {
        saving = true
        defer { saving = false }

        let keyToSend: String? = apiKeyTouched ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let voiceToSend: String? = voiceIdTouched ? voiceId.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        if keyToSend == nil && voiceToSend == nil {
            statusMessage = "Nothing to save."
            statusKind = .info
            return
        }

        if let k = keyToSend, k.isEmpty {
            statusMessage = "API key cannot be empty. Leave the field untouched to keep the current key."
            statusKind = .error
            return
        }

        let result = await viewModel.saveSettings(apiKey: keyToSend, voiceId: voiceToSend)

        switch result {
        case .success(let voiceMeta):
            var msg = "Saved."
            if let name = voiceMeta?.name, !name.isEmpty {
                msg += " Default voice: \(name)."
            }
            statusMessage = msg
            statusKind = .ok
            apiKeyTouched = false
            voiceIdTouched = false
            apiKey = ""
            if let id = viewModel.settings?.voiceId { voiceId = id }
        case .failure(let error):
            statusMessage = error
            statusKind = .error
        }
    }
}

// MARK: - Monthly Usage Bar (with expected-pace marker)

private struct MonthlyUsageBar: View {
    let used: Int
    let limit: Int
    let expectedPct: Double
    let status: ElevenLabsUsage.Status

    private var fraction: Double {
        limit > 0 ? min(Double(used) / Double(limit), 1.0) : 0
    }

    private var tint: Color {
        switch status {
        case .ok:        return .green
        case .watch:     return .yellow
        case .warning:   return .orange
        case .critical:  return .red
        case .exhausted: return .red
        case .unknown:   return .accentColor
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.18))
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.gradient)
                    .frame(width: geo.size.width * CGFloat(fraction))
                // Expected-pace marker — vertical bar where Sir SHOULD be at this point
                if expectedPct > 0 && expectedPct < 100 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: 12)
                        .offset(x: geo.size.width * CGFloat(min(expectedPct / 100.0, 1.0)) - 0.75)
                }
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Usage Bar

private struct UsageBar: View {
    let label: String
    let current: Int
    let max: Int

    private var fraction: Double {
        max > 0 ? min(Double(current) / Double(max), 1.0) : 0
    }

    private var tint: Color {
        if fraction > 0.9 { return .red }
        if fraction > 0.7 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text("\(current) / \(max)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .tint(tint)
        }
    }
}
