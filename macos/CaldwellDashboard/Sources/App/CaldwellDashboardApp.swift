import SwiftUI

@main
struct CaldwellDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView(viewModel: appDelegate.viewModel)
        } label: {
            // Glyph reflects mute state so Sir can see at a glance
            // from the menubar without opening the popover.
            Image(systemName: appDelegate.viewModel.isMuted
                ? "speaker.slash.fill"
                : "person.bust.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
