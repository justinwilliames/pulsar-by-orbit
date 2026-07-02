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
    /// Base slot position relative to the head-zone centre. An arc slot while a
    /// speaker holds the centre, or a symmetric-cluster slot when the swarm is
    /// idle. The organic drift is layered on top of this.
    let slotOffset: CGSize
    /// Stable index for a per-drone bob phase offset.
    let index: Int
    /// Honour Reduce Motion — freeze the bob + pause blink when on.
    var reduceMotion: Bool = false
    let portraitManager: PortraitManager

    private var color: Color { droneColor(for: category) }
    /// This drone's signature motion (amplitude + frequency), Pulsar-neutral for
    /// the orbiting Pulsar thumbnail.
    private var motion: DroneRegistry.MotionTrait { droneMotion(for: category) }

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

    /// Stable per-category bob phase derived from the category string's hash.
    /// Using `orbitIndex` caused a snap: when a participant moves centre→orbit
    /// its index becomes its real slot index (was hardcoded 0 at centre), so the
    /// phase jumped on transition. A category hash is constant regardless of
    /// position, so the drift runs continuously through the swap.
    private var stablePhase: Double {
        let h = abs(category.hashValue)
        // Map the hash into [0, 2π) and scale to give similar spread as the old
        // index-based formula (index * 1.7 ≈ 0…10 for 7 drones → wrap to 2π).
        return Double(h % 1000) / 1000.0 * 2.0 * .pi
    }

    var body: some View {
        TimelineView(schedule) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            // [FIX 4 — bob phase] Derive phase from category hash, not orbitIndex.
            // orbitIndex is 0 at centre and snaps to the real slot index when the
            // participant enters orbit, causing a visible drift-phase jump on
            // centre→orbit transition. stablePhase is constant for the lifetime of
            // the drone, so the bob motion is continuous through the swap.
            let phase = stablePhase
            // SWARM DRIFT: each drone wanders on its own gentle, slightly
            // out-of-phase path so the cluster reads as a living pod hovering
            // together, not icons pinned to a track. Two summed sines per axis at
            // incommensurate rates give an organic, non-repeating drift; the
            // amplitude is a touch wider than a simple bob so the group visibly
            // mingles. Frozen under Reduce Motion.
            let amp = reduceMotion ? 0 : Double(motion.bobAmplitude) * 1.6
            let f = motion.bobFrequency
            let driftX = (sin(time * 0.9 * f + phase) + 0.5 * sin(time * 1.7 * f + phase * 2.3)) * amp
            let driftY = (cos(time * 0.7 * f + phase * 0.6) + 0.5 * cos(time * 1.3 * f + phase * 1.9)) * (amp * 0.85)

            PortraitView(
                voiceName: category,
                amplitude: 0,
                size: thumbnailSize,
                voiceColor: color,
                portraitManager: portraitManager,
                droneName: category
            )
            // Each drone keeps its OWN coloured glow so the swarm reads as a
            // cluster of distinct, glowing characters.
            .shadow(color: color.opacity(0.45), radius: 6)
            .offset(
                x: slotOffset.width + driftX,
                y: slotOffset.height + driftY
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
}
