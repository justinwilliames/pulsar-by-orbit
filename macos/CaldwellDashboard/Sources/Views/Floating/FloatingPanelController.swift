import AppKit
import SwiftUI

final class FloatingPanelController: NSPanel {
    /// Head-zone footprint (matches `FloatingHeadsView.headZone*`). The visible
    /// head + glow live here; the caption grows above or below it.
    static let headZoneWidth: CGFloat = FloatingHeadsView.headZoneWidth   // 240
    static let headZoneHeight: CGFloat = FloatingHeadsView.headZoneHeight // 200

    /// Panel is widened to the caption max (280) so a full-width caption is always
    /// contained; the 240 head zone is centred within it. Clamping the panel's X
    /// into the screen then guarantees the caption never crosses a side edge.
    static let panelWidth: CGFloat = SubtitleBubbleView.maxWidth          // 280

    /// Margin kept between the panel and every screen edge.
    private let screenMargin: CGFloat = 16

    /// Shared geometry the SwiftUI view reads to render the caption on the right
    /// side. The controller owns the source of truth.
    let layout = FloatingLayoutModel()

    /// Top-left of the HEAD ZONE in screen coords. The head stays pinned here
    /// regardless of which side the caption takes; the panel frame is derived
    /// from this anchor + the current caption height + edge.
    private var headTopLeft: NSPoint?

    /// Latest reported caption height (the CURRENT revealed height — grows as the
    /// typewriter fills in). 0 = no caption.
    private var captionHeight: CGFloat = 0

    /// The full text's measured height, locked once per line, used to pick the
    /// above/below placement UPFRONT so the box never flips as it grows. nil =
    /// not yet locked.
    private var lockedFullHeight: CGFloat?
    /// The placement edge chosen from `lockedFullHeight`, held for the line.
    private var lockedEdge: FloatingLayoutModel.CaptionEdge?

    /// Suppress the move handler while WE are setting the frame (so our own
    /// programmatic resizes don't get mistaken for a user drag).
    private var isAdjustingFrame = false

    init(viewModel: DashboardViewModel) {
        super.init(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: Self.panelWidth, height: Self.headZoneHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false

        let rootView = FloatingHeadsView(
            viewModel: viewModel,
            layout: layout,
            onCaptionHeightChange: { [weak self] height in
                self?.updateCaptionHeight(height)
            },
            onFullCaptionHeight: { [weak self] fullHeight in
                self?.lockPlacement(forFullCaptionHeight: fullHeight)
            }
        )
        contentView = NSHostingView(rootView: rootView)

        // Re-evaluate placement after a user drag (the panel can be moved anywhere
        // via isMovableByWindowBackground).
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification, object: self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - First show: sensible default top-left anchor

    /// Anchor the HEAD at the top-left of the screen's visible area on first show
    /// (or whenever no anchor is known). Sets `headTopLeft` then lays out the
    /// frame. This replaces the old origin-`.zero` default that left the head
    /// stuck in the bottom-left corner.
    func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        // Only default to the top-left on the FIRST show (or after the anchor was
        // cleared). A position the user has dragged Pulsar to persists across
        // utterances — we just re-evaluate caption placement at that spot.
        if headTopLeft == nil {
            let centringSlack = (Self.panelWidth - Self.headZoneWidth) / 2
            let headLeftX = vf.minX + screenMargin - centringSlack
            let headTopY = vf.maxY - screenMargin
            headTopLeft = NSPoint(x: headLeftX, y: headTopY)
        }
        relayout(animated: false)
    }

    // MARK: - Placement lock (decided from the FULL text upfront)

    /// Lock the above/below placement from the full line's measured height the
    /// first time it's reported for a line. After this, the box grows only in the
    /// locked direction as the typewriter fills it in — it never flips.
    private func lockPlacement(forFullCaptionHeight fullHeight: CGFloat) {
        let h = max(0, fullHeight.rounded(.up))
        guard h > 0 else { return }
        // Re-lock only if the full height meaningfully changed (i.e. a new line),
        // not on every measurement tick.
        if let existing = lockedFullHeight, abs(existing - h) < 1 { return }
        lockedFullHeight = h
        lockedEdge = chooseEdge(forCaptionHeight: h)
        relayout(animated: true)
    }

    /// Picks BELOW when the full caption fits beneath the head, else ABOVE.
    private func chooseEdge(forCaptionHeight capH: CGFloat) -> FloatingLayoutModel.CaptionEdge {
        guard let screen = self.screen ?? NSScreen.main, let anchor = headTopLeft else { return .below }
        let vf = screen.visibleFrame
        let roomBelow = (anchor.y - Self.headZoneHeight) - (vf.minY + screenMargin)
        return (capH > 0 && roomBelow < capH) ? .above : .below
    }

    // MARK: - Caption height → relayout

    private func updateCaptionHeight(_ rawHeight: CGFloat) {
        let h = max(0, rawHeight.rounded(.up))
        guard abs(h - captionHeight) > 0.5 else { return }
        captionHeight = h
        relayout(animated: true)
    }

    /// Recompute the caption edge (below if it fits, else above), clamp the panel
    /// fully on screen, and set the frame — keeping the HEAD pinned to
    /// `headTopLeft`. Grows downward for a below-caption, upward for an above one.
    private func relayout(animated: Bool) {
        guard let screen = self.screen ?? NSScreen.main else { return }
        guard let anchor = headTopLeft else { return }
        let vf = screen.visibleFrame

        let headH = Self.headZoneHeight
        let capH = captionHeight

        // Placement direction is LOCKED from the full text upfront so the box
        // never flips above/below while it grows. Before the lock lands (first
        // frame), fall back to a live decision from the current height.
        let edge: FloatingLayoutModel.CaptionEdge =
            lockedEdge ?? chooseEdge(forCaptionHeight: capH)

        let totalH = headH + capH
        // Panel top edge in screen coords:
        //  - below: panel top == head top (head occupies top of panel)
        //  - above: panel top == head top + capH (caption sits above the head)
        let panelTopY = (edge == .above) ? (anchor.y + capH) : anchor.y
        var originY = panelTopY - totalH
        // headTopLeft is the HEAD's top-left; the panel's left edge is the head's
        // left minus the centring slack (head zone is centred in the wider panel).
        var originX = anchor.x - (Self.panelWidth - Self.headZoneWidth) / 2

        // Clamp the whole panel inside the visible frame so neither the head nor
        // the (centred, ≤panel-width) caption can cross any screen edge.
        originX = min(max(originX, vf.minX + screenMargin), vf.maxX - Self.panelWidth - screenMargin)
        originY = min(max(originY, vf.minY + screenMargin), vf.maxY - totalH - screenMargin)

        let newFrame = NSRect(x: originX, y: originY, width: Self.panelWidth, height: totalH)

        layout.captionEdge = edge
        layout.captionXOffset = 0   // caption is centred in the panel; panel-clamp handles edges

        isAdjustingFrame = true
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.30
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(newFrame, display: true)
            } completionHandler: { [weak self] in
                self?.isAdjustingFrame = false
            }
        } else {
            setFrame(newFrame, display: true)
            isAdjustingFrame = false
        }
    }

    // MARK: - User drag → recompute anchor

    @objc private func panelDidMove(_ note: Notification) {
        guard !isAdjustingFrame else { return }
        // The user dragged the panel. Recover the head's top-left from the new
        // frame given the current edge, then re-evaluate placement (the new
        // position may have flipped which side the caption fits on).
        let f = frame
        let headLeftX = f.minX + (Self.panelWidth - Self.headZoneWidth) / 2
        let headTopY: CGFloat = (layout.captionEdge == .above)
            ? f.maxY - captionHeight       // caption is above; head top is below it
            : f.maxY                        // head is at the panel top
        headTopLeft = NSPoint(x: headLeftX, y: headTopY)
        // The new position may have changed which side the FULL caption fits on —
        // re-evaluate the locked edge from the known full height at this spot.
        if let full = lockedFullHeight {
            lockedEdge = chooseEdge(forCaptionHeight: full)
        }
        relayout(animated: false)
    }

    // MARK: - Hide → collapse to head-only

    /// Drop the caption height so the next appearance starts head-only; keeps the
    /// current head anchor so it reappears where it was.
    func resetToBaseSize() {
        captionHeight = 0
        lockedFullHeight = nil   // next line re-locks its placement fresh
        lockedEdge = nil
        layout.captionEdge = .below
        if headTopLeft != nil { relayout(animated: false) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
