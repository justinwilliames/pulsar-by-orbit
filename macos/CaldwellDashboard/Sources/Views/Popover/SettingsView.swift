import AppKit
import Sparkle
import SwiftUI

struct SettingsView: View {
    let viewModel: DashboardViewModel
    let updater: SPUUpdater

    @State private var statusMessage: String?
    @State private var statusKind: StatusKind = .info
    @State private var personaSaving: Bool = false

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
                CheckForUpdatesView(updater: updater)
            }
            .padding(16)
        }
        .task {
            await viewModel.loadSettings()
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
        let result = await viewModel.saveSettings(expletivesEnabled: expletivesEnabled)
        if case .failure(let error) = result {
            statusMessage = "Mode change failed: \(error)"
            statusKind = .error
        }
    }

    // MARK: - Voice (local voice picker + message style + install nudge)

    @ViewBuilder
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VOICE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            if let voices = viewModel.settings?.availableVoices, !voices.isEmpty {
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
        }
    }

    private var nativeVoiceBinding: Binding<String> {
        Binding(
            get: {
                // native_voice is the resolved variant (e.g. "Daniel (Enhanced)");
                // the picker tags are base names, so strip the quality suffix.
                (viewModel.settings?.nativeVoice ?? "Daniel")
                    .replacingOccurrences(of: " (Enhanced)", with: "")
                    .replacingOccurrences(of: " (Premium)", with: "")
            },
            set: { newValue in Task { await viewModel.setNativeVoice(newValue) } }
        )
    }

    private var canonEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings?.canonEnabled ?? true },
            set: { newValue in Task { await viewModel.setCanonEnabled(newValue) } }
        )
    }

    private var canonHint: String {
        if viewModel.settings?.canonEnabled == false {
            return "Off — bespoke only: richer, fewer lines."
        }
        return "On — frequent short “Pushed, Sir.”-style pings at turn-end."
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
            if viewModel.settings?.enhancedInstalled == false {
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
}
