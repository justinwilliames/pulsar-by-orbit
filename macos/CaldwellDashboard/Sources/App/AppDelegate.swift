import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatingPanel: FloatingPanelController?
    private var httpServer: CaldwellHTTPServer?
    let viewModel = DashboardViewModel()

    // Minimum time the panel stays visible after isActive flips to false.
    // Short cached phrases ("Pushed.") finish in ~1s — without enough of
    // a tail, the panel appears and disappears before Sir notices it. 6s
    // gives proper presence for the cached short canon while still
    // dismissing automatically.
    private static let minVisibleDuration: TimeInterval = 6.0
    private var hideWorkItem: DispatchWorkItem?
    private var lastShownAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        floatingPanel = FloatingPanelController(viewModel: viewModel)

        viewModel.onPlaybackChanged = { [weak self] isActive in
            DispatchQueue.main.async {
                self?.updateFloatingPanel(isActive: isActive)
            }
        }

        viewModel.connect()

        // Start the in-process HTTP server. Phase 5 is complete: the Swift
        // app is now the sole listener on port 7865.
        httpServer = CaldwellHTTPServer()
        httpServer?.start()
        if let httpServer {
            Task {
                await httpServer.configure()
            }
        }

        NSLog("[Caldwell] AppDelegate finished launching, floatingPanel=\(floatingPanel != nil), SSE connecting, httpServer on \(CaldwellHTTPServer.migrationPort)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        httpServer?.stop()
    }

    private func updateFloatingPanel(isActive: Bool) {
        guard let panel = floatingPanel else {
            NSLog("[Caldwell] updateFloatingPanel called but panel is nil")
            return
        }
        NSLog("[Caldwell] updateFloatingPanel isActive=\(isActive) wasVisible=\(panel.isVisible)")
        if isActive {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            if !panel.isVisible {
                panel.positionOnScreen()
                // orderFrontRegardless bypasses macOS 26's stricter activation
                // rules for non-activating panels — orderFront alone can be
                // ignored when the app has LSUIElement=true and no key window.
                panel.orderFrontRegardless()
                lastShownAt = Date()
                NSLog("[Caldwell] Panel ordered front at \(panel.frame)")
            }
        } else {
            scheduleHide(panel: panel)
        }
    }

    private func scheduleHide(panel: FloatingPanelController) {
        hideWorkItem?.cancel()
        let elapsed = lastShownAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = max(0, Self.minVisibleDuration - elapsed)
        // No isPlaying guard here. The cancellation mechanism in
        // updateFloatingPanel(isActive: true) is the correct interlock:
        // if a new line starts before this fires, it cancels the item.
        // If it fires, nothing is playing — hide unconditionally.
        // The old isPlaying guard caused the panel to stick permanently
        // when isPlaying was transiently true at fire time (SSE lag).
        let item = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
            NSLog("[Caldwell] Panel ordered out after min-visible elapsed")
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
    }
}
