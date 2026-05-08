import SwiftUI

@main
struct CaldwellDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Caldwell", systemImage: "person.bust.fill") {
            PopoverRootView(viewModel: appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
