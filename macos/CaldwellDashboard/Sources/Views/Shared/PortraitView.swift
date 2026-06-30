import SwiftUI

/// Pulsar's animated portrait.
///
/// Blends 5 rendered frames of the robot — mouth closed (0) → full open (4) —
/// driven by `amplitude`. The amplitude is exponentially smoothed and mapped to
/// a continuous position across the frame strip; the two adjacent frames are
/// crossfaded by opacity, so the mouth appears to move continuously through the
/// rendered art rather than snapping between discrete frames.
///
/// One robot for all voices (`voiceName` is ignored for the image, kept only for
/// the fallback monogram + API stability). The external signature is unchanged so
/// NowPlayingView / FloatingPortraitView keep working.
struct PortraitView: View {
    let voiceName: String
    let amplitude: Float
    let size: CGFloat
    let voiceColor: Color
    let portraitManager: PortraitManager

    /// The 5 rendered mouth frames, loaded once (closed → full open).
    @State private var frames: [NSImage] = PortraitView.loadFrames()

    /// Exponentially-smoothed amplitude in 0…1, used to position across frames.
    @State private var smoothedAmp: CGFloat = 0
    @State private var lastTick: Double = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                if frames.count == 5 {
                    frameStack(at: smoothedAmp)
                } else {
                    fallback
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                if amplitude > 0 {
                    Circle()
                        .stroke(voiceColor.opacity(0.6), lineWidth: 2)
                        .shadow(color: voiceColor.opacity(0.4), radius: 6)
                }
            }
            .onChange(of: timeline.date) { _, _ in
                advance(now: t)
            }
        }
    }

    // MARK: - Frame crossfade

    /// Renders the two frames adjacent to the continuous amplitude position and
    /// crossfades between them. `amp` (0…1) maps linearly onto positions 0…4.
    @ViewBuilder
    private func frameStack(at amp: CGFloat) -> some View {
        let pos = max(0, min(1, amp)) * CGFloat(frames.count - 1)  // 0…4
        let lower = Int(floor(pos))
        let upper = min(lower + 1, frames.count - 1)
        let frac = pos - CGFloat(lower)                            // 0…1 blend

        ZStack {
            // Lower (more-closed) frame underneath, full opacity.
            Image(nsImage: frames[lower])
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)

            // Upper (more-open) frame on top, faded in by the blend fraction.
            if upper != lower {
                Image(nsImage: frames[upper])
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .opacity(Double(frac))
            }
        }
    }

    @ViewBuilder private var fallback: some View {
        Circle()
            .fill(voiceColor.opacity(0.3))
            .overlay {
                Text(String(voiceName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(voiceColor)
            }
    }

    // MARK: - Drive

    /// Eases the smoothed amplitude toward the live value each timeline tick, so
    /// the crossfade glides instead of stepping with raw amplitude updates.
    private func advance(now t: Double) {
        let dt = lastTick == 0 ? 0 : min(0.1, t - lastTick)
        lastTick = t
        let target = CGFloat(max(0, min(1, amplitude)))
        let k = 1 - pow(0.001, dt)        // fast but smooth follow
        smoothedAmp += (target - smoothedAmp) * k
    }

    // MARK: - Loading

    /// Loads pulsar-mouth-0…4 from the bundle. Returns an empty array if any
    /// frame is missing, which triggers the fallback monogram.
    private static func loadFrames() -> [NSImage] {
        var out: [NSImage] = []
        for i in 0..<5 {
            guard let img = NSImage(named: "pulsar-mouth-\(i)") else { return [] }
            out.append(img)
        }
        return out
    }
}
