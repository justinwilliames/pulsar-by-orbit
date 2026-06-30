import SwiftUI

/// A small orbiting sibling "drone" portrait.
///
/// Rendered once per in-flight sub-agent, hovering around the main Pulsar head.
/// It uses the drone's own frame set (`<category>-mouth-0…4` + `<category>-blink`
/// via `PortraitView(droneName:)`) and its locked brand colour for the glow.
///
/// When this drone is the ACTIVE SPEAKER (a narration line tagged with its
/// category), it pops larger and receives the live amplitude so its mouth
/// lip-syncs; otherwise it idles at amplitude 0 at the thumbnail size.
struct FloatingDronePortraitView: View {
    /// The drone category — also the frame prefix and the colour key.
    let category: String
    /// Whether this drone currently owns the spoken line.
    let isActiveSpeaker: Bool
    /// Live mouth amplitude (only meaningful while active).
    let liveAmplitude: Float
    /// Resting thumbnail size; the active speaker pops larger than this.
    let thumbnailSize: CGFloat
    /// Orbit placement around the main head.
    let orbitRadius: CGFloat
    let orbitYOffset: CGFloat
    let angle: Double
    /// Stable index for a per-drone bob phase offset.
    let index: Int
    let portraitManager: PortraitManager

    private var color: Color { droneColor(for: category) }

    /// The active speaker POPS large — clearly bigger than the idle drones AND
    /// bigger than a shrunken Pulsar (120·0.48 ≈ 58pt): 40·2.4 ≈ 96pt. Idle
    /// in-flight drones stay at thumbnail size in the orbit.
    private var activeScale: CGFloat { isActiveSpeaker ? 2.4 : 1.0 }

    /// When active, the drone is PULLED toward centre — only ~28% of its orbit
    /// offset remains — so it moves forward into the spotlight rather than
    /// popping out at the rim. Idle drones keep their full orbit offset.
    private var radiusFactor: CGFloat { isActiveSpeaker ? 0.28 : 1.0 }

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = Double(index) * 1.7
            let bobX = sin(time * 0.9 + phase) * 2.0
            let bobY = cos(time * 0.7 + phase * 0.6) * 1.5

            PortraitView(
                voiceName: category,
                amplitude: isActiveSpeaker ? liveAmplitude : 0,
                size: thumbnailSize,
                voiceColor: color,
                portraitManager: portraitManager,
                droneName: category
            )
            // Full, rich glow when speaking; a quiet hint when idle.
            .shadow(color: color.opacity(isActiveSpeaker ? 0.85 : 0.3),
                    radius: isActiveSpeaker ? 16 : 4)
            .shadow(color: color.opacity(isActiveSpeaker ? 0.5 : 0),
                    radius: isActiveSpeaker ? 6 : 0)
            .scaleEffect(activeScale)
            .offset(
                x: cos(angle) * orbitRadius * radiusFactor + bobX,
                y: sin(angle) * orbitRadius * radiusFactor
                    + orbitYOffset * radiusFactor + bobY
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isActiveSpeaker)
        }
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.1)
                    .combined(with: .opacity)
                    .combined(with: .offset(y: 30)),
                removal: .scale(scale: 1.4)
                    .combined(with: .opacity)
                    .combined(with: .offset(y: -60))
            )
        )
    }
}
