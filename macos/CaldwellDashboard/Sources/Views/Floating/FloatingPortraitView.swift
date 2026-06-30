import SwiftUI

/// Pulsar's floating head.
///
/// Brand-locked to Orbit indigo (no per-voice tint, no rainbow hue-shift). The
/// head sits inside a soft, *glowing* squircle halo that breathes on a steady
/// pulsar heartbeat — all glow, no hard lines, and every animated element
/// follows the portrait's squircle silhouette rather than fighting it with
/// circles.
///
/// The portrait is clipped to a squircle (corner radius = size * 0.22,
/// `.continuous`), so the aura, the expanding pulse ripples and the rim glow
/// are all squircle-shaped and concentric with it — the energy reads as
/// parallel to the rounded-square. Everything is driven continuously by one
/// `TimelineView(.animation)` clock — there is deliberately NO
/// `.animation(value: amplitude)` (a spring on top of the 60Hz amplitude feed
/// is what caused the old stutter).
struct FloatingPortraitView: View {
    let voiceName: String
    let amplitude: Float
    let voiceColor: Color            // kept for API parity; NOT used for the glow
    let portraitManager: PortraitManager

    private let portraitSize: CGFloat = 120

    /// Pulsar beat period, seconds. One "pulse" per beat.
    private let beatPeriod: Double = 1.4

    /// Continuous-curvature corner radius for the portrait squircle — kept in
    /// lockstep with `PortraitView.squircle` (size * 0.22) so every glow layer
    /// hugs the actual clipped edge instead of a mismatched circle.
    private var cornerRadius: CGFloat { portraitSize * 0.22 }

    /// Corner-radius *ratio* — reused so ripples drawn at any scale keep the
    /// same squircle proportions as the portrait.
    private let cornerRatio: CGFloat = 0.22

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
                // Back → front. All squircle-shaped, all soft glow.
                pulseRipples(time: time, amp: amp)     // expanding glowing squircle ripples
                auraGlow(pulse: pulse, amp: amp)       // soft blurred squircle halo
                rimGlow(pulse: pulse, amp: amp)        // bright squircle rim glow hugging the edge

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

    // MARK: - Soft squircle aura (behind the head)

    /// A soft, blurred indigo halo in the *squircle* shape, sitting just behind
    /// the portrait and breathing with the beat. This is the replacement for the
    /// old circular radial bloom + rotating beams: one diffuse glow that hugs
    /// the rounded-square outline. Two stacked, differently-blurred squircles
    /// give the glow depth — a tight inner brightness and a wide outer falloff.
    @ViewBuilder
    private func auraGlow(pulse: Double, amp: Double) -> some View {
        let intensity = 0.22 + amp * 0.34 + pulse * 0.20
        // The halo swells very slightly on each beat so it reads as a pulse of
        // light rather than a static gradient.
        let swell = portraitSize + 14 + CGFloat(amp * 22 + pulse * 10)

        ZStack {
            // Wide, very soft outer falloff.
            RoundedRectangle(cornerRadius: (swell * cornerRatio) + 26, style: .continuous)
                .fill(core)
                .frame(width: swell + 52, height: swell + 52)
                .blur(radius: 34)
                .opacity(intensity * 0.85)

            // Tighter, brighter inner glow hugging the edge.
            RoundedRectangle(cornerRadius: (swell * cornerRatio) + 12, style: .continuous)
                .fill(light)
                .frame(width: swell + 22, height: swell + 22)
                .blur(radius: 18)
                .opacity(intensity)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    // MARK: - Expanding glowing squircle ripples

    /// Soft, blurred, *glowing* squircle ripples that scale outward from the
    /// portrait's squircle and fade — the pulsar "pulse" expressed as ripples of
    /// light in the rounded-square shape, NOT thin sharp ring strokes. Each
    /// ripple is a thick, soft-edged squircle band (drawn wide then blurred) so
    /// it reads as glow travelling outward. Two ripples run a half-beat apart
    /// for rhythm; both intensify with amplitude.
    @ViewBuilder
    private func pulseRipples(time: Double, amp: Double) -> some View {
        Canvas { context, size in
            context.addFilter(.blur(radius: 7))          // soft-edge every ripple

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseHalf = portraitSize / 2

            func ripple(phase: Double, tint: Color, gain: Double) {
                // 0 → 1 across the beat; grows outward and fades as it goes.
                let half = baseHalf + 2 + phase * (24 + amp * 34)
                // Ease-out fade so the ripple is brightest just after release.
                let fade = pow(1.0 - phase, 1.6)
                let opacity = fade * (0.30 + amp * 0.50) * gain
                guard opacity > 0.015 else { return }
                // Thick, soft band — width tapers as the ripple expands so it
                // dissolves into the dark rather than thinning to a hard line.
                let width = (7.0 + amp * 5.0) * (1.0 - phase * 0.5)
                glowSquircle(context, center: center, half: half,
                             color: tint.opacity(opacity), width: width)
            }

            let beat = fmod(time, beatPeriod) / beatPeriod
            ripple(phase: beat, tint: light, gain: 1.0)

            let beat2 = fmod(time + beatPeriod / 2, beatPeriod) / beatPeriod
            ripple(phase: beat2, tint: muted, gain: 0.55)
        }
        .frame(width: portraitSize + 110, height: portraitSize + 110)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    // MARK: - Rim glow (hugging the edge)

    /// A soft, bright squircle rim of light hugging the portrait edge, brightening
    /// on each beat. Replaces the old crisp 1.4pt neon stroke: this is a blurred
    /// glow band following the exact squircle, so the head sits *in* light rather
    /// than being outlined by a hard line.
    @ViewBuilder
    private func rimGlow(pulse: Double, amp: Double) -> some View {
        let side = portraitSize + 6
        let intensity = 0.30 + amp * 0.34 + pulse * 0.30

        RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
            .stroke(light.opacity(intensity), lineWidth: 3.5 + pulse * 2.0)
            .frame(width: side, height: side)
            .blur(radius: 4 + pulse * 2)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    // MARK: - Canvas helper

    /// Strokes a squircle with the same 0.22 corner ratio as the portrait, at an
    /// arbitrary half-side. Used for the expanding ripples; the Canvas-level blur
    /// filter turns each (deliberately thick) stroke into a soft glowing band.
    private func glowSquircle(_ context: GraphicsContext, center: CGPoint,
                              half: CGFloat, color: Color, width: CGFloat) {
        let rect = CGRect(x: center.x - half, y: center.y - half,
                          width: half * 2, height: half * 2)
        let path = RoundedRectangle(cornerRadius: half * 2 * cornerRatio,
                                    style: .continuous).path(in: rect)
        context.stroke(path, with: .color(color), lineWidth: width)
    }
}
