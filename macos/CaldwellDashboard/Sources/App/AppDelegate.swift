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

    // Tail after audio finishes — the head holds ~5s so there's a beat to read
    // the caption, then fades out (a longer hover reads as the speaker
    // overstaying). The caption linger in FloatingHeadsView is set LONGER than
    // this + the 0.9s fade on purpose, so the subtitle stays visible through the
    // fade and dissolves with the head rather than snapping out first.
    private static let tailAfterIdle: TimeInterval = 5.0
    // Absolute ceiling on visibility, measured from when the panel was
    // first shown. Hard belt-and-braces against a dropped/missed idle SSE
    // event leaving the portrait stuck on screen forever. Generous enough to
    // cover a long line + the 10s read tail.
    private static let maxVisibleDuration: TimeInterval = 45.0
    private var hideWorkItem: DispatchWorkItem?
    /// True while the panel is mid fade-out, so a new line can abort it.
    private var isFadingOut = false
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
            if isFadingOut {
                // A new line arrived mid fade-out — abort it and restore him.
                isFadingOut = false
                panel.alphaValue = 1
            }
            if !panel.isVisible {
                panel.alphaValue = 1
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
                guard let self else { return }
                // The ceiling is a safety net for a STUCK panel (a dropped idle
                // event leaving the overlay up forever) — NOT a cap on legitimate
                // activity. If participants are genuinely still present (a running
                // sub-agent drone, or Pulsar mid-line), don't yank the panel; just
                // re-arm the ceiling. Yanking an active panel was the bug that left
                // voices playing into a dark screen: the panel hid, the view model
                // never learned, and with drones permanently present no show edge
                // could re-fire. Only hide when nothing should be visible anymore.
                if self.viewModel.panelShouldBeVisible {
                    self.scheduleMaxVisible()
                } else {
                    self.hidePanel(reason: "max-visible-ceiling")
                }
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
        guard let panel = floatingPanel, panel.isVisible else {
            floatingPanel?.orderOut(nil)
            viewModel.playback.currentVoice = nil
            viewModel.playback.currentText = nil
            viewModel.playback.currentAgentCategory = nil
            floatingPanel?.resetToBaseSize()
            viewModel.panelWasHidden()
            return
        }
        // Slow, gentle fade rather than a snap: animate the whole panel's alpha to
        // 0, then order it out, clear state, and reset alpha + footprint — unless a
        // new line revived him mid-fade (the isFadingOut guard). Tune `duration`.
        isFadingOut = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.9
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.isFadingOut else { return }
            self.isFadingOut = false
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.viewModel.playback.currentVoice = nil
            self.viewModel.playback.currentText = nil
            panel.resetToBaseSize()
            self.viewModel.panelWasHidden()
        }
        NSLog("[Pulsar] Panel hidden (\(reason))")
    }
}
