import SwiftUI

@main
struct CaldwellDashboardApp: App {
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
            Image(systemName: appDelegate.viewModel.isMuted
                ? "waveform.circle"
                : "waveform.circle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
