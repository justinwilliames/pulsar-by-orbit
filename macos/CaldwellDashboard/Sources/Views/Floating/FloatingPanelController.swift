import AppKit
import SwiftUI

final class FloatingPanelController: NSPanel {
    init(viewModel: DashboardViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        // .statusBar is above .floating — needed on macOS 26 to surface above
        // other transient windows (notification banners, mission-control overlays)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        // No window shadow: on a borderless transparent panel (esp. macOS 26
        // Liquid Glass) the shadow renders as a glassy rounded-rect "box"
        // framing the head. The glow provides all the depth; let it float free.
        hasShadow = false
        isMovableByWindowBackground = true
        // .stationary keeps the panel pinned across Spaces transitions even when
        // the user navigates between desktops mid-utterance.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: FloatingHeadsView(viewModel: viewModel))
        contentView = hostingView
    }

    func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelFrame = frame
        let x = visibleFrame.minX + 16
        let y = visibleFrame.maxY - panelFrame.height - 16
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
