import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatingPanel: FloatingPanelController?
    private var httpServer: CaldwellHTTPServer?
    private var aboutWindow: NSWindow?
    let viewModel = DashboardViewModel()

    // Sparkle auto-update. `startingUpdater: true` begins the background
    // scheduled check loop (interval governed by Sparkle defaults). Exposed
    // so the popover's "Check for Updates" button can drive a manual check.
    // The feed + EdDSA key live in Info.plist (SUFeedURL / SUPublicEDKey);
    // CI signs each DMG with the matching private key.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // Tail after audio finishes — kept long enough to read the final caption
    // line in full before the head + bubble fade out together. Matches the
    // caption linger in FloatingHeadsView so head and subtitle leave in sync.
    private static let tailAfterIdle: TimeInterval = 10.0
    // Absolute ceiling on visibility, measured from when the panel was
    // first shown. Hard belt-and-braces against a dropped/missed idle SSE
    // event leaving the portrait stuck on screen forever. Generous enough to
    // cover a long line + the 10s read tail.
    private static let maxVisibleDuration: TimeInterval = 45.0
    private var hideWorkItem: DispatchWorkItem?
    private var maxVisibleWorkItem: DispatchWorkItem?

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

        NSLog("[Pulsar] AppDelegate finished launching, floatingPanel=\(floatingPanel != nil), SSE connecting, httpServer on \(CaldwellHTTPServer.migrationPort)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        httpServer?.stop()
    }

    func showAbout() {
        if let existing = aboutWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Pulsar"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
    }

    private func updateFloatingPanel(isActive: Bool) {
        guard let panel = floatingPanel else {
            NSLog("[Pulsar] updateFloatingPanel called but panel is nil")
            return
        }

        // Honour the floating-head setting. When off, the head never appears —
        // the voice still plays. If it's somehow on screen (setting flipped
        // mid-utterance), take it down now.
        guard CaldwellConfig.shared.floatingHeadEnabled else {
            if panel.isVisible {
                hidePanel(reason: "floating-head-disabled")
            }
            return
        }

        NSLog("[Pulsar] updateFloatingPanel isActive=\(isActive) wasVisible=\(panel.isVisible)")
        if isActive {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            if !panel.isVisible {
                panel.positionOnScreen()
                // orderFrontRegardless bypasses macOS 26's stricter activation
                // rules for non-activating panels — orderFront alone can be
                // ignored when the app has LSUIElement=true and no key window.
                panel.orderFrontRegardless()
                NSLog("[Pulsar] Panel ordered front at \(panel.frame)")
                scheduleMaxVisible()
            }
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hidePanel(reason: "tail-after-idle")
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tailAfterIdle, execute: item)
    }

    /// Hard ceiling — if anything goes wrong with SSE idle events, this
    /// kicks the panel off screen after maxVisibleDuration regardless.
    private func scheduleMaxVisible() {
        maxVisibleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hidePanel(reason: "max-visible-ceiling")
            }
        }
        maxVisibleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxVisibleDuration, execute: item)
    }

    private func hidePanel(reason: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        maxVisibleWorkItem?.cancel()
        maxVisibleWorkItem = nil
        floatingPanel?.orderOut(nil)
        viewModel.playback.currentVoice = nil
        viewModel.playback.currentText = nil
        // Collapse back to the head-only footprint so the next appearance starts
        // at base height (the caption resize re-grows it if needed) and no stale
        // tall transparent area lingers off-screen.
        floatingPanel?.resetToBaseSize()
        NSLog("[Pulsar] Panel hidden (\(reason))")
    }
}
