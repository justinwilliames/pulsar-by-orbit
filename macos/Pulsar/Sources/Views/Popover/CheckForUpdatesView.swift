import Combine
import Sparkle
import SwiftUI

/// Tracks whether Sparkle is currently able to start a check — it can't
/// while a check or install is already in flight, so the button disables
/// itself. This mirrors Sparkle's documented SwiftUI integration pattern
/// (publisher on `canCheckForUpdates` → `@Published`).
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Updates" block in Settings — shows the running version and a manual
/// "Check for Updates…" button. Sparkle handles the rest (download, EdDSA
/// signature validation against SUPublicEDKey, in-place install + relaunch).
struct CheckForUpdatesView: View {
    private let updater: SPUUpdater
    @StateObject private var viewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UPDATES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            HStack {
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .controlSize(.small)
                .disabled(!viewModel.canCheckForUpdates)
            }
        }
    }
}
