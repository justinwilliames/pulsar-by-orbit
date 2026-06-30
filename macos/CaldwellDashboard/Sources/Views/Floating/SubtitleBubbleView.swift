import SwiftUI

/// Read-along caption bubble shown next to the floating Pulsar head.
///
/// On-brand and visually fused to the head: the rim uses the SAME glow recipe as
/// `FloatingPortraitView.rimGlow` (Orbit-indigo `.orbitLight`, identical base +
/// pulse intensity, width and blur), driven by the SHARED `PulsarPulse` so the
/// bubble and head breathe on the exact same beat.
///
/// Reveal is a TYPEWRITER: the text appears progressively as Pulsar speaks
/// (`revealedCount` advances with playback), then holds the full line through the
/// linger. The box GROWS to fit the currently-revealed text — it reads as being
/// written into and expanding — reaching full size at the end. The placement
/// DIRECTION (above/below the head) is locked upfront from the full text's
/// measured size by the controller, so the box only ever grows in one direction
/// and never flips mid-reveal. Long lines grow the box vertically with NO
/// truncation; `maxHeight` caps it to the space the panel can give on screen.
struct SubtitleBubbleView: View {
    /// The complete line (reserves the box size and ensures no truncation).
    let fullText: String
    /// How many characters of `fullText` are currently revealed (typewriter).
    let revealedCount: Int
    /// Which edge the tail points from — `.top` when below the head, `.bottom`
    /// when above.
    var tailEdge: Edge = .top
    /// Hard ceiling on bubble height so an extreme line still fits on screen.
    var maxHeight: CGFloat = .greatestFiniteMagnitude

    static let maxWidth: CGFloat = 280

    private var core: Color { .orbit }        // #6366F1 — matches the head
    private var light: Color { .orbitLight }  // #818CF8 — the head's rim glow tint

    /// The revealed prefix of the full text.
    private var revealed: String {
        let n = max(0, min(revealedCount, fullText.count))
        return String(fullText.prefix(n))
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = PulsarPulse.pulse(at: t)

            // Gentle hover, harmonised with the head. The head bobs at
            // `sin(time * 1.1) * 2.5` (vertical only); the bubble shares the same
            // clock + rhythm with a small phase offset for life, plus a very
            // slight slower horizontal sway. Amplitudes are tiny so the caption
            // still reads as ATTACHED, just alive.
            let bobY = sin(t * 1.1 + 0.6) * 2.5
            let bobX = sin(t * 0.7 + 0.3) * 1.2

            content
                .background(bubbleBackground)
                .overlay { rimGlow(pulse: pulse) }
                .overlay(alignment: tailEdge == .top ? .top : .bottom) {
                    tail(pulse: pulse)
                }
                // Same soft indigo core shadow as the head, pulsing in step.
                .shadow(color: core.opacity(0.18 + pulse * 0.22),
                        radius: 6 + pulse * 5)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .offset(x: bobX, y: bobY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Text content (full-size box, typewriter overlay)

    /// Sizes to the REVEALED text so the box grows as the typewriter fills it in.
    /// Placement direction is locked upstream from the full text, so growing here
    /// never causes an above/below flip.
    private var content: some View {
        captionText(revealed)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: Self.maxWidth)
            .frame(maxHeight: maxHeight)
    }

    private func captionText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)   // no truncation — wrap fully
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Glass + glow (matched to the head)

    private var bubbleBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(core.opacity(0.28))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.35))
        }
    }

    /// Identical recipe to `FloatingPortraitView.rimGlow`: a soft, bright indigo
    /// rim hugging the edge, brightening on each beat. The head has an amplitude
    /// term too; the caption has no audio amplitude, so it uses the head's
    /// resting baseline + the same pulse term.
    @ViewBuilder
    private func rimGlow(pulse: Double) -> some View {
        let intensity = 0.30 + pulse * 0.30
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(light.opacity(intensity), lineWidth: 3.5 + pulse * 2.0)
            .blur(radius: 4 + pulse * 2)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func tail(pulse: Double) -> some View {
        CaptionTail(pointingUp: tailEdge == .top)
            .fill(.ultraThinMaterial)
            .overlay { CaptionTail(pointingUp: tailEdge == .top).fill(core.opacity(0.28)) }
            .overlay {
                CaptionTail(pointingUp: tailEdge == .top)
                    .stroke(light.opacity(0.30 + pulse * 0.30), lineWidth: 1)
                    .blur(radius: 1 + pulse)
                    .blendMode(.plusLighter)
            }
            .frame(width: 16, height: 8)
            .offset(y: tailEdge == .top ? -7 : 7)
    }
}

/// A triangle tail for the bubble — points up (toward a head above) or down.
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
