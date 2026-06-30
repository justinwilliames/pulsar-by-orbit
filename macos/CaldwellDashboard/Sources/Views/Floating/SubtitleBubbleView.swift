import SwiftUI

/// Read-along caption bubble shown next to the floating Pulsar head.
///
/// On-brand to match the head's glow aesthetic: a translucent dark/indigo glass
/// pill with a soft Orbit-indigo glow rim, white text, and a small tail pointing
/// toward the head (UP when the bubble sits below the head, DOWN when above).
/// Full-line reveal — the whole caption appears at once (the text is fully known
/// before Pulsar speaks); no typewriter, no karaoke.
///
/// Lifecycle (fade in/out, linger, cross-fade) is owned by the parent
/// `FloatingHeadsView`; this view just renders whatever text it's handed.
struct SubtitleBubbleView: View {
    let text: String
    /// Which edge the tail points from — `.top` when the bubble is below the
    /// head (tail points up), `.bottom` when above (tail points down).
    var tailEdge: Edge = .top

    /// Caption sizing. Kept in sync with the panel's width reservation.
    static let maxWidth: CGFloat = 280
    private let lineLimit = 4

    private var core: Color { .orbit }        // #6366F1
    private var light: Color { .orbitLight }  // #818CF8

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: Self.maxWidth)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(core.opacity(0.28))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(light.opacity(0.55), lineWidth: 1)
                    .blur(radius: 1.5)
                    .blendMode(.plusLighter)
            }
            .overlay(alignment: tailEdge == .top ? .top : .bottom) {
                CaptionTail(pointingUp: tailEdge == .top)
                    .fill(.ultraThinMaterial)
                    .overlay { CaptionTail(pointingUp: tailEdge == .top).fill(core.opacity(0.28)) }
                    .frame(width: 16, height: 8)
                    .offset(y: tailEdge == .top ? -7 : 7)
            }
            .shadow(color: core.opacity(0.35), radius: 10)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .allowsHitTesting(false)
    }
}

/// A triangle tail for the bubble — points up (toward a head above) or down
/// (toward a head below).
private struct CaptionTail: Shape {
    var pointingUp: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointingUp {
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}
