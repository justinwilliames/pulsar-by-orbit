import SwiftUI

struct SettingsView: View {
    let viewModel: DashboardViewModel

    @State private var apiKey: String = ""
    @State private var voiceId: String = ""
    @State private var apiKeyTouched: Bool = false
    @State private var voiceIdTouched: Bool = false
    @State private var saving: Bool = false
    @State private var statusMessage: String?
    @State private var statusKind: StatusKind = .info
    @State private var showingApiKey: Bool = false
    @State private var personaSaving: Bool = false

    enum StatusKind { case ok, error, info }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                personaSection
                Divider()
                apiKeySection
                voiceIdSection
                saveButton
                statusBanner
                Divider()
                usageSection
            }
            .padding(16)
        }
        .task {
            await viewModel.loadSettings()
            await viewModel.loadUsage()
            // Sync local fields once after load
            if !voiceIdTouched, let id = viewModel.settings?.voiceId {
                voiceId = id
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

    @ViewBuilder
    private var voiceIdSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEFAULT VOICE ID")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            TextField("20-character voice ID", text: $voiceId)
                .textFieldStyle(.roundedBorder)
                .onChange(of: voiceId) { _, _ in voiceIdTouched = true }

            Text("Add the voice to your VoiceLab on elevenlabs.io first, then paste its ID. Validated against ElevenLabs on save.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
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
                        .glassEffect(.regular.tint(.accentColor), in: Capsule())
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
        VStack(alignment: .leading, spacing: 8) {
            Text("DAEMON CAPS — TODAY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

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
                Text("Daily caps reset at local midnight.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Loading…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func runRateBadge(_ eleven: ElevenLabsUsage) -> some View {
        let (label, colour) = runRateLabel(for: eleven.status)
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular.tint(colour), in: Capsule())
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
