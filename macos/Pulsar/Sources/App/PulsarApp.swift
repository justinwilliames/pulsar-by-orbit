import SwiftUI

@main
struct PulsarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView(
                viewModel: appDelegate.viewModel,
                updater: appDelegate.updaterController.updater
            )
        } label: {
            // Pulsar's waveform mark, reflecting mute state at a glance from the
            // menubar without opening the popover — FILLED when active, OUTLINE
            // when muted. Deliberately NOT a "slash" variant: that camouflages
            // among the system audio icons and reads as "gone", leaving the user
            // unable to find it to unmute.
            //
            // Ambient push: when Task Mode is on and ≥1 session is Paused
            // (waiting on the user), a small orange dot rides the icon's top-
            // trailing corner — a glanceable dispatch signal. Cleared the instant
            // the paused count hits 0, and never shown when Task Mode is off.
            Image(systemName: appDelegate.viewModel.isMuted
                ? "waveform.circle"
                : "waveform.circle.fill")
                .overlay(alignment: .topTrailing) {
                    if appDelegate.viewModel.showsPausedBadge {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
