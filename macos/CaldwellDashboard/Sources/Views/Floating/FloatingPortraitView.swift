import SwiftUI

/// Pulsar's floating head.
///
/// Brand-locked to Orbit indigo (no per-voice tint, no rainbow hue-shift). The
/// glow reads as an actual *pulsar*: a slow rotating two-beam sweep behind the
/// head, plus a rhythmic heartbeat glow and an expanding ring on a steady beat.
/// Everything is driven continuously by one `TimelineView(.animation)` clock —
/// there is deliberately NO `.animation(value: amplitude)` (a spring on top of
/// the 60Hz amplitude feed is what caused the old stutter).
struct FloatingPortraitView: View {
    let voiceName: String
    let amplitude: Float
    let voiceColor: Color            // kept for API parity; NOT used for the glow
    let portraitManager: PortraitManager

    private let portraitSize: CGFloat = 120

    /// Pulsar beat period, seconds. One "pulse" per beat.
    private let beatPeriod: Double = 1.4

    // Fixed Pulsar palette.
    private var core: Color { .orbit }        // #6366F1
    private var light: Color { .orbitLight }  // #818CF8
    private var muted: Color { .orbitMuted }  // #A5B4FC

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let amp = Double(amplitude)

            // Beat phase 0…1 across one period; `pulse` is a sharp-attack,
            // soft-decay heartbeat shape (bright flash, gentle fade).
            let beat = fmod(time, beatPeriod) / beatPeriod
            let pulse = heartbeat(beat)

            ZStack {
                // Back → front.
                beamSweep(time: time, amp: amp)        // rotating pulsar beams
                outerGlow(pulse: pulse, amp: amp)      // soft indigo bloom
                pulseRings(time: time, amp: amp)       // crisp expanding beat ring
                heartCore(pulse: pulse, amp: amp)      // tight bright neon rim

                PortraitView(
                    voiceName: voiceName,
                    amplitude: amplitude,
                    size: portraitSize,
                    voiceColor: voiceColor,
                    portraitManager: portraitManager
                )
            }
            // Gentle time-driven bob + a soft amplitude scale-pulse, plus a tiny
            // extra lift on each beat so the whole head "throbs" with the pulsar.
            // No `.animation(value:)` — the timeline already animates this.
            .scaleEffect(1.0 + amp * 0.05 + pulse * 0.015)
            .offset(y: sin(time * 1.1) * 2.5)
            .shadow(color: core.opacity(0.18 + amp * 0.22 + pulse * 0.1),
                    radius: 4 + amp * 6 + pulse * 4)
        }
    }

    // MARK: - Heartbeat shape

    /// Maps a 0…1 beat phase to a 0…1 intensity with a fast attack and a soft
    /// exponential decay — the characteristic pulsar "throb".
    private func heartbeat(_ phase: Double) -> Double {
        // Quick rise over the first ~12% of the beat, then decay.
        if phase < 0.12 {
            return phase / 0.12                      // 0 → 1 attack
        }
        let decay = (phase - 0.12) / 0.88            // 0 → 1 over the rest
        return exp(-decay * 3.2)                     // 1 → ~0.04 fade
    }

    // MARK: - Pulsar beam-sweep (behind the head)

    /// Two soft opposing indigo beams slowly rotating behind the portrait, like
    /// a pulsar's lighthouse beams. Low opacity, slow rotation.
    @ViewBuilder
    private func beamSweep(time: Double, amp: Double) -> some View {
        let rotation = Angle.radians(time * 0.22)    // slow sweep
        let intensity = 0.20 + amp * 0.22

        ZStack {
            beam()
            beam().rotationEffect(.degrees(180))     // opposing beam
        }
        .rotationEffect(rotation)
        .frame(width: portraitSize + 96, height: portraitSize + 96)
        .blur(radius: 14)
        .opacity(intensity)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    /// A single wedge-shaped beam fading out from the centre.
    @ViewBuilder
    private func beam() -> some View {
        let size = portraitSize + 96
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: light.opacity(0.9), location: 0.06),
                .init(color: .clear, location: 0.16),
                .init(color: .clear, location: 1.00),
            ]),
            center: .center,
            angle: .degrees(-8)
        )
        .frame(width: size, height: size)
        .mask(
            RadialGradient(
                colors: [.white, .white.opacity(0.5), .clear],
                center: .center,
                startRadius: portraitSize * 0.18,
                endRadius: size * 0.55
            )
        )
    }

    // MARK: - Outer glow bloom

    /// Soft fixed-indigo bloom behind the head, breathing gently with the beat
    /// and lifting with amplitude. Replaces the old rainbow aurora.
    @ViewBuilder
    private func outerGlow(pulse: Double, amp: Double) -> some View {
        let opacity = 0.16 + amp * 0.28 + pulse * 0.12

        RadialGradient(
            colors: [core.opacity(0.9), core.opacity(0.35), .clear],
            center: .center,
            startRadius: portraitSize * 0.30,
            endRadius: portraitSize * 0.66
        )
        .frame(width: portraitSize + 56, height: portraitSize + 56)
        .blur(radius: 16)
        .opacity(opacity)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    // MARK: - Crisp neon beat rings

    /// A crisp thin expanding ring released on each beat (the pulsar "ping"),
    /// plus a tight steady rim. Sharp lines + a little glow, not a soft blur.
    @ViewBuilder
    private func pulseRings(time: Double, amp: Double) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = portraitSize / 2

            // Expanding "ping" ring, re-emitted every beat. Reads as the pulse
            // travelling outward. Present even when quiet, stronger when loud.
            let beat = fmod(time, beatPeriod) / beatPeriod
            let ringProgress = beat                          // 0 → 1 across the beat
            let ringRadius = baseRadius + 3 + ringProgress * (18 + amp * 26)
            let ringOpacity = (1.0 - ringProgress) * (0.30 + amp * 0.45)

            if ringOpacity > 0.02 {
                strokeCircle(context, center: center, radius: ringRadius,
                             color: light.opacity(ringOpacity), width: 1.6)
            }

            // A second, fainter ring a half-beat out of phase for rhythm.
            let beat2 = fmod(time + beatPeriod / 2, beatPeriod) / beatPeriod
            let r2Radius = baseRadius + 3 + beat2 * (18 + amp * 26)
            let r2Opacity = (1.0 - beat2) * (0.14 + amp * 0.22)
            if r2Opacity > 0.02 {
                strokeCircle(context, center: center, radius: r2Radius,
                             color: muted.opacity(r2Opacity), width: 1.2)
            }
        }
        .frame(width: portraitSize + 80, height: portraitSize + 80)
        .allowsHitTesting(false)
    }

    /// Tight bright neon rim hugging the head, brightening on each beat — the
    /// crisp cybernetic accent that matches the headset's neon lines.
    @ViewBuilder
    private func heartCore(pulse: Double, amp: Double) -> some View {
        let rim = portraitSize / 2 + 2
        let intensity = 0.35 + amp * 0.4 + pulse * 0.25

        Circle()
            .stroke(light.opacity(intensity), lineWidth: 1.4)
            .frame(width: rim * 2, height: rim * 2)
            .shadow(color: core.opacity(0.5 + pulse * 0.3), radius: 3 + pulse * 3)
            .allowsHitTesting(false)
    }

    // MARK: - Canvas helper

    private func strokeCircle(_ context: GraphicsContext, center: CGPoint,
                              radius: CGFloat, color: Color, width: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        context.stroke(Circle().path(in: rect), with: .color(color), lineWidth: width)
    }
}
