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
    /// The complete line.
    let fullText: String
    /// When this caption appeared. The typewriter reveals from here on a LOCAL
    /// wall-clock, independent of the unreliable playback `elapsed`/`duration` —
    /// so it always completes, then holds.
    let startedAt: Date
    /// When true (speech ended / linger), show the FULL text immediately.
    let holdFull: Bool
    /// Reveal pace ≈ the `say -r` speaking rate (words/min → chars/sec).
    static let charsPerSecond: Double = Double(NativeVoiceClient.defaultRate) / 60.0 * 5.5
    /// Which edge the tail points from — `.top` when below the head, `.bottom`
    /// when above.
    var tailEdge: Edge = .top
    /// Hard ceiling on bubble height so an extreme line still fits on screen.
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    /// Rim-glow tint. Defaults to Pulsar indigo (`.orbitLight`); the active
    /// drone's colour themes the rim when a sub-agent owns the line.
    var activeColor: Color = .orbitLight

    /// Bubble box max width. Kept NARROWER than the hosting panel width (280) by
    /// ≥ the glow/shadow radius on each side, so the outer glow fades fully
    /// inside the panel and never hard-cuts at the left/right edge.
    static let maxWidth: CGFloat = 248
    private let tailHeight: CGFloat = 8
    /// Reserve on every side for the bubble's outer glow/shadow to fade before
    /// the panel edge (max core-shadow radius ≈ 11pt + rim blur ≈ 6pt). Used by
    /// the caption zone padding + the panel height math.
    static let glowMargin: CGFloat = 16

    /// True when no drone owns the line (the default Pulsar indigo tint).
    private var isPulsarTint: Bool { activeColor == .orbitLight }
    /// The bubble's tint — drives the fill wash + core shadow. Pulsar keeps its
    /// deeper `#6366F1`; a speaking drone tints the whole bubble to its colour.
    private var core: Color { isPulsarTint ? .orbit : activeColor }
    /// The rim-glow tint — Pulsar indigo by default, the active drone's colour
    /// when a sub-agent owns the line.
    private var light: Color { activeColor }

    /// The revealed prefix at time `now`: time-based from `startedAt` (always
    /// completes), or the full text once `holdFull`. Snapped UP to a word boundary
    /// so partial words don't flash.
    private func revealed(at now: Date) -> String {
        let count = fullText.count
        guard count > 0 else { return "" }
        if holdFull { return fullText }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let target = Int((elapsed * Self.charsPerSecond).rounded(.up))
        let chars = Array(fullText)
        var n = min(max(target, 0), count)
        while n < count && !chars[n].isWhitespace { n += 1 }   // finish the word
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

            content(revealed(at: timeline.date))
                .background(bubbleBackground)
                .overlay { rimGlow(pulse: pulse) }
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
    private func content(_ revealed: String) -> some View {
        captionText(revealed)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .padding(tailEdge == .top ? .top : .bottom, tailHeight)  // room for the tail
            .frame(maxWidth: Self.maxWidth)
        // NO maxHeight frame: that let the bubble EXPAND to fill offered space
        // (the container proposes ~infinite height), stranding the text in a
        // giant empty box. fixedSize on the Text already prevents truncation, so
        // the bubble hugs the wrapped text's intrinsic height and grows naturally
        // line-by-line as the typewriter reveals more.
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
        // ONE shape for box + tail so the tail is genuinely part of the bubble.
        // The base stays a dark gradient for TEXT LEGIBILITY, but the bottom stop
        // is pulled toward the speaker's colour and a stronger colour wash sits on
        // top — so the bubble OBVIOUSLY reads as the active speaker's hue at a
        // glance (azure for Sentinel, indigo for Pulsar) rather than a faint tint.
        let shape = SpeechBubbleShape(tailOnTop: tailEdge == .top, tailHeight: tailHeight)
        return shape
            // Dark base for text legibility…
            .fill(LinearGradient(
                colors: [Color(.sRGB, red: 0.14, green: 0.14, blue: 0.26, opacity: 1),
                         Color(.sRGB, red: 0.09, green: 0.09, blue: 0.18, opacity: 1)],
                startPoint: .top, endPoint: .bottom))
            // …then a strong speaker-colour wash so the hue reads at a glance:
            // a flat tint plus a brighter top-down gradient of the same colour.
            .overlay { shape.fill(core.opacity(0.30)) }
            .overlay {
                shape.fill(LinearGradient(
                    colors: [core.opacity(0.30), core.opacity(0.12)],
                    startPoint: .top, endPoint: .bottom))
            }
    }

    /// Identical recipe to `FloatingPortraitView.rimGlow`: a soft, bright rim
    /// hugging the edge, brightening on each beat — tinted to the active speaker.
    /// Stronger than before so the speaker colour reads clearly around the bubble.
    @ViewBuilder
    private func rimGlow(pulse: Double) -> some View {
        let intensity = 0.55 + pulse * 0.35
        SpeechBubbleShape(tailOnTop: tailEdge == .top, tailHeight: tailHeight)
            .stroke(light.opacity(intensity), lineWidth: 4.0 + pulse * 2.0)
            .blur(radius: 4 + pulse * 2)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

}

/// The whole bubble as ONE shape: a rounded rectangle with a triangular tail
/// protruding from the top (head above) or bottom (head below). Filled once, the
/// tail is genuinely part of the box; stroked, the glow rim flows around the tail.
private struct SpeechBubbleShape: Shape {
    var tailOnTop: Bool
    var cornerRadius: CGFloat = 14
    var tailWidth: CGFloat = 18
    var tailHeight: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let bodyRect = tailOnTop
            ? CGRect(x: rect.minX, y: rect.minY + tailHeight,
                     width: rect.width, height: rect.height - tailHeight)
            : CGRect(x: rect.minX, y: rect.minY,
                     width: rect.width, height: rect.height - tailHeight)
        var p = Path(roundedRect: bodyRect, cornerRadius: cornerRadius, style: .continuous)
        let midX = rect.midX
        let half = tailWidth / 2
        if tailOnTop {
            p.move(to: CGPoint(x: midX - half, y: bodyRect.minY + 1))
            p.addLine(to: CGPoint(x: midX, y: rect.minY))
            p.addLine(to: CGPoint(x: midX + half, y: bodyRect.minY + 1))
        } else {
            p.move(to: CGPoint(x: midX - half, y: bodyRect.maxY - 1))
            p.addLine(to: CGPoint(x: midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: midX + half, y: bodyRect.maxY - 1))
        }
        p.closeSubpath()
        return p
    }
}
