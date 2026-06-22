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
            // Glyph reflects mute state so Sir can see at a glance from the
            // menubar without opening the popover. Always the Caldwell bust
            // so he stays recognisable — FILLED when active, OUTLINE when
            // muted. (Previously muted swapped to speaker.slash.fill, which
            // camouflaged him among the system audio icons and read as
            // "gone" — the user couldn't find him to unmute.)
            Image(systemName: appDelegate.viewModel.isMuted
                ? "person.bust"
                : "person.bust.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
