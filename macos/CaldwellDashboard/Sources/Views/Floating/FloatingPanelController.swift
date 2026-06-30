import AppKit
import SwiftUI

final class FloatingPanelController: NSPanel {
    /// Head-only footprint — the panel's idle size when no caption is showing.
    static let baseSize = NSSize(width: 240, height: 260)

    init(viewModel: DashboardViewModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.baseSize),
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

        // The SwiftUI view reports its desired total height (head zone + caption,
        // when shown) so the panel can grow DOWNWARD to fit the bubble and shrink
        // back when it clears — never a permanent tall transparent panel (the
        // empty area would block clicks behind it).
        let rootView = FloatingHeadsView(viewModel: viewModel) { [weak self] height in
            self?.resize(toContentHeight: height)
        }
        let hostingView = NSHostingView(rootView: rootView)
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

    /// Grow/shrink the panel to fit the reported content height, anchored at the
    /// TOP-LEFT — the top edge stays put and the window extends downward. In
    /// macOS (origin bottom-left) that means keeping `frame.maxY` constant.
    private func resize(toContentHeight rawHeight: CGFloat) {
        let height = max(Self.baseSize.height, rawHeight.rounded(.up))
        guard abs(height - frame.height) > 0.5 else { return }

        let topY = frame.maxY                      // fixed top edge
        let newOrigin = NSPoint(x: frame.minX, y: topY - height)
        let newFrame = NSRect(origin: newOrigin,
                              size: NSSize(width: frame.width, height: height))

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(newFrame, display: true)
        }
    }

    /// Snap back to head-only height without animation (used when hidden), so
    /// the next appearance starts compact and re-grows for any caption.
    func resetToBaseSize() {
        guard frame.height != Self.baseSize.height else { return }
        let topY = frame.maxY
        let newFrame = NSRect(x: frame.minX, y: topY - Self.baseSize.height,
                              width: frame.width, height: Self.baseSize.height)
        setFrame(newFrame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
