import SwiftUI

/// Shared layout state between `FloatingPanelController` (which owns the on-screen
/// geometry) and `FloatingHeadsView` (which renders head + caption).
///
/// The controller decides — from the panel's CURRENT screen position — whether the
/// caption fits BELOW the head or must flip ABOVE it, and how far to inset the
/// caption horizontally so a 280pt bubble never crosses a screen edge. The view
/// reads this to stack the caption on the correct side and nudge it sideways.
@MainActor
@Observable
final class FloatingLayoutModel {
    enum CaptionEdge { case below, above }

    /// Which side of the head the caption renders on.
    var captionEdge: CaptionEdge = .below

    /// Horizontal offset (points) applied to the caption so it stays fully on
    /// screen. Positive = shift right (head near left edge), negative = shift
    /// left (head near right edge), 0 = centered under the head.
    var captionXOffset: CGFloat = 0
}
