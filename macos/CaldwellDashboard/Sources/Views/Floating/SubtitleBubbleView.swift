import SwiftUI

/// Read-along caption bubble shown below the floating Pulsar head.
///
/// On-brand to match the head's glow aesthetic: a translucent dark/indigo glass
/// pill with a soft Orbit-indigo glow rim, white text, and a small tail pointing
/// UP toward the head. Full-line reveal — the whole caption appears at once (the
/// text is fully known before Pulsar speaks); no typewriter, no karaoke.
///
/// Lifecycle (fade in/out, linger, cross-fade) is owned by the parent
/// `FloatingHeadsView`; this view just renders whatever text it's handed.
struct SubtitleBubbleView: View {
    let text: String

    /// Caption sizing. Kept in sync with `FloatingHeadsView.bubbleMaxWidth` so
    /// the panel can reserve the right width.
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
                    // Dark glass base — translucent so the desktop reads through,
                    // tinted indigo to belong to the head's palette.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(core.opacity(0.28))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                }
            }
            .overlay {
                // Soft glow rim hugging the bubble edge — the same light-indigo
                // halo language as the head's rimGlow, kept subtle.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(light.opacity(0.55), lineWidth: 1)
                    .blur(radius: 1.5)
                    .blendMode(.plusLighter)
            }
            .overlay(alignment: .top) {
                // Small tail pointing UP toward the head, glass-matched.
                CaptionTail()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        CaptionTail().fill(core.opacity(0.28))
                    }
                    .frame(width: 16, height: 8)
                    .offset(y: -7)
            }
            .shadow(color: core.opacity(0.35), radius: 10)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .allowsHitTesting(false)
    }
}

/// An upward-pointing triangle for the bubble's tail.
private struct CaptionTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
