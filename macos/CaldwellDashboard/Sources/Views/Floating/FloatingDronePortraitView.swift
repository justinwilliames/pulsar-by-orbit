import SwiftUI

/// A small orbiting sibling "drone" portrait.
///
/// Rendered once per in-flight sub-agent, hovering around the main Pulsar head.
/// It uses the drone's own frame set (`<category>-mouth-0…4` + `<category>-blink`
/// via `PortraitView(droneName:)`) and its locked brand colour for the glow.
///
/// Each drone moves with its OWN signature motion (from `DroneRegistry`), not a
/// shared bob — so the characters read as distinct, not mere recolours. Idle
/// (non-speaking) drones run their bob at a throttled ~20fps; only the active
/// speaker (which lives in the centre slot, never here) needs full 60Hz. When
/// `reduceMotion` is on, the bob freezes entirely.
struct FloatingDronePortraitView: View {
    /// The drone category — also the frame prefix and the colour key.
    let category: String
    /// Whether this drone currently owns the spoken line. In the place-swap
    /// design the speaker lives in the CENTRE slot, so an orbiting drone is
    /// never the active speaker — kept for API stability / future use.
    let isActiveSpeaker: Bool
    /// Live mouth amplitude (only meaningful while active).
    let liveAmplitude: Float
    /// Resting thumbnail size.
    let thumbnailSize: CGFloat
    /// Orbit placement around the main head.
    let orbitRadius: CGFloat
    let orbitYOffset: CGFloat
    let angle: Double
    /// Stable index for a per-drone bob phase offset.
    let index: Int
    /// Honour Reduce Motion — freeze the bob + pause blink when on.
    var reduceMotion: Bool = false
    /// How many drones of this TYPE are in flight. >1 shows a "×N" count badge so
    /// the viewer can tell how many of each character are running; 1 → no badge.
    var countBadge: Int = 1
    let portraitManager: PortraitManager

    private var color: Color { droneColor(for: category) }
    /// This drone's signature motion (amplitude + frequency), Pulsar-neutral for
    /// the orbiting Pulsar thumbnail.
    private var motion: DroneRegistry.MotionTrait { droneMotion(for: category) }
    /// Role badge letter (nil for Pulsar).
    private var badge: String? { droneBadge(for: category) }

    /// Idle drones animate at ~20fps (cheaper); the active speaker would run
    /// full 60Hz, but it isn't rendered here. Reduce-Motion pauses the clock.
    /// One concrete `AnimationTimelineSchedule` so the `TimelineView` type is
    /// stable across states (interval ~20fps idle / 60fps active, paused when
    /// Reduce Motion is on).
    private var schedule: AnimationTimelineSchedule {
        AnimationTimelineSchedule(
            minimumInterval: isActiveSpeaker ? 1.0 / 60.0 : 1.0 / 20.0,
            paused: reduceMotion
        )
    }

    var body: some View {
        TimelineView(schedule) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = Double(index) * 1.7
            // Per-drone signature bob (frozen under Reduce Motion).
            let amp = reduceMotion ? 0 : Double(motion.bobAmplitude)
            let f = motion.bobFrequency
            let bobX = sin(time * 0.9 * f + phase) * amp
            let bobY = cos(time * 0.7 * f + phase * 0.6) * (amp * 0.75)

            PortraitView(
                voiceName: category,
                amplitude: 0,
                size: thumbnailSize,
                voiceColor: color,
                portraitManager: portraitManager,
                droneName: category
            )
            .overlay(alignment: .topTrailing) { roleBadge }
            .overlay(alignment: .bottomTrailing) { countPill }
            .shadow(color: color.opacity(0.3), radius: 4)
            .offset(
                x: cos(angle) * orbitRadius + bobX,
                y: sin(angle) * orbitRadius + orbitYOffset + bobY
            )
        }
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.1)
                    .combined(with: .opacity)
                    .combined(with: .offset(y: 30)),
                // Evicted/finished drones FADE + drift up rather than popping.
                removal: .scale(scale: 0.6)
                    .combined(with: .opacity)
                    .combined(with: .offset(y: -24))
            )
        )
    }

    /// A "×N" count pill in the lower corner when this TYPE has >1 drone in
    /// flight — so the viewer can read how many of each character are running.
    @ViewBuilder
    private var countPill: some View {
        if countBadge > 1 {
            Text("×\(countBadge)")
                .font(.system(size: thumbnailSize * 0.26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, thumbnailSize * 0.12)
                .padding(.vertical, thumbnailSize * 0.04)
                .background(Capsule().fill(color.opacity(0.95)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .offset(x: thumbnailSize * 0.14, y: thumbnailSize * 0.12)
                .allowsHitTesting(false)
        }
    }

    /// Tiny role badge in the portrait corner — a non-colour distinguisher so
    /// the drones are tellable apart even with similar hues (P5). Pulsar = none.
    @ViewBuilder
    private var roleBadge: some View {
        if let badge {
            Text(badge)
                .font(.system(size: thumbnailSize * 0.28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: thumbnailSize * 0.42, height: thumbnailSize * 0.42)
                .background(Circle().fill(color))
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .offset(x: thumbnailSize * 0.10, y: -thumbnailSize * 0.10)
                .allowsHitTesting(false)
        }
    }
}
