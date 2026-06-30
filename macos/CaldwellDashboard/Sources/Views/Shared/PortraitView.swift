import SwiftUI

/// Pulsar's animated "digital face".
///
/// One rendered robot base (a front-facing robot with a blank glowing screen)
/// is composited under a PROCEDURALLY-DRAWN face — glowing cyan/indigo eyes,
/// brows and a mouth painted live in SwiftUI on the robot's screen. This lets
/// eyes/brows/mouth animate independently:
///   • Mouth  → driven continuously by `amplitude` (closed line → wide aperture).
///   • Eyes   → autonomous blink on a varying timer + a subtle idle drift.
///   • Brows  → neutral at rest; lift + "engaged" inward tilt while speaking.
///
/// A `TimelineView(.animation)` provides a continuous ~60fps clock so blink and
/// idle motion run regardless of how often `amplitude` updates.
///
/// External signature is unchanged so NowPlayingView / FloatingPortraitView keep
/// working. `voiceName` no longer selects an image (one robot for all voices) but
/// is retained for the fallback monogram and API stability.
struct PortraitView: View {
    let voiceName: String
    let amplitude: Float
    let size: CGFloat
    let voiceColor: Color
    let portraitManager: PortraitManager

    // MARK: Screen calibration (fractions of `size`)
    //
    // The base is square (512²) and shown aspectRatio(.fill) in a square frame,
    // so image fractions map 1:1 onto `size`. The dark screen glass spans roughly
    // x[0.30, 0.70], y[0.32, 0.50] of the image. Features are placed within that.
    private enum Screen {
        static let centerX: CGFloat = 0.500
        static let eyeY: CGFloat    = 0.388   // eye row (upper screen)
        static let mouthY: CGFloat  = 0.480   // mouth centre, LOWER screen
        static let browY: CGFloat   = 0.330   // brow row, just above eyes (rest)
        static let eyeDX: CGFloat   = 0.098   // half-distance between eyes
        static let eyeD: CGFloat    = 0.120   // eye diameter — BIG & ROUND
        static let browW: CGFloat   = 0.072   // brow bar length (subtle)
        static let mouthMaxW: CGFloat = 0.230 // mouth width when fully open
        static let mouthMinW: CGFloat = 0.130 // mouth width when closed (line)
    }

    // MARK: Smoothed drive signals
    @State private var smoothedAmp: CGFloat = 0   // eased amplitude (mouth)
    @State private var speaking: CGFloat = 0      // slow envelope (brow engage)

    // MARK: Blink state (driven off the timeline clock)
    @State private var nextBlinkAt: Double = 1.5
    @State private var blinkStart: Double = -1
    @State private var lastTick: Double = 0

    @State private var baseImage: NSImage? = PortraitView.loadBase()

    private let glow = Color(red: 0.36, green: 0.78, blue: 1.0)        // cyan
    private let core = Color(red: 0.78, green: 0.95, blue: 1.0)        // bright core
    private let deep = Color(red: 0.30, green: 0.42, blue: 1.0)        // indigo edge

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let blink = blinkAmount(now: t)        // 1 = open, ~0.08 = shut
            let drift = sin(t * 0.9) * 0.004       // tiny idle vertical drift (frac)

            ZStack {
                base

                // Procedural face, drawn in the screen region.
                faceLayer(eyeBlink: blink, drift: drift)
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

    // MARK: - Base image

    @ViewBuilder private var base: some View {
        if let baseImage {
            Image(nsImage: baseImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            // Fallback monogram (image missing) — keeps the old behaviour.
            Circle()
                .fill(voiceColor.opacity(0.3))
                .overlay {
                    Text(String(voiceName.prefix(1)).uppercased())
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(voiceColor)
                }
        }
    }

    // MARK: - Procedural face

    @ViewBuilder
    private func faceLayer(eyeBlink: CGFloat, drift: CGFloat) -> some View {
        let amp = smoothedAmp
        let spk = speaking

        ZStack {
            // ---- Brows ----
            brow(side: -1, speaking: spk, drift: drift)
            brow(side:  1, speaking: spk, drift: drift)

            // ---- Eyes ----
            eye(side: -1, blink: eyeBlink, drift: drift)
            eye(side:  1, blink: eyeBlink, drift: drift)

            // ---- Mouth ----
            mouth(openness: amp)
        }
        // Only the procedural face needs the additive glow; the base already glows.
        .compositingGroup()
    }

    // MARK: Eyes

    @ViewBuilder
    private func eye(side: CGFloat, blink: CGFloat, drift: CGFloat) -> some View {
        let d = Screen.eyeD * size                    // big round eye
        let x = (Screen.centerX + side * Screen.eyeDX) * size
        let y = (Screen.eyeY + drift) * size

        ZStack {
            // Gentle outer halo — soft, not blown-out, so eyes read as distinct.
            Circle()
                .fill(glow)
                .frame(width: d * 1.18, height: d * 1.18)
                .blur(radius: d * 0.30)
                .opacity(0.40)

            // Iris — radial cyan with a bright centre, like the master's eyes.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [core, glow, deep],
                        center: .init(x: 0.42, y: 0.38),
                        startRadius: 0,
                        endRadius: d * 0.62
                    )
                )
                .frame(width: d, height: d)
                .shadow(color: glow.opacity(0.7), radius: d * 0.16)

            // Bright catch-light highlight, upper-left (friendly, alive).
            Circle()
                .fill(core)
                .frame(width: d * 0.30, height: d * 0.30)
                .blur(radius: d * 0.04)
                .offset(x: -d * 0.16, y: -d * 0.18)

            // Tiny secondary sparkle, lower-right.
            Circle()
                .fill(.white)
                .frame(width: d * 0.10, height: d * 0.10)
                .opacity(0.85)
                .offset(x: d * 0.14, y: d * 0.16)
        }
        .scaleEffect(x: 1.0, y: max(0.08, blink), anchor: .center)
        .position(x: x, y: y)
    }

    // MARK: Brows

    @ViewBuilder
    private func brow(side: CGFloat, speaking: CGFloat, drift: CGFloat) -> some View {
        let w = Screen.browW * size
        let hBar = max(2, size * 0.013)

        // FRIENDLY brows: flat at rest, a tiny SYMMETRIC up-raise when speaking
        // (attentive). NEVER angled inward-down — that reads angry. No tilt at all.
        let lift = speaking * size * 0.012
        let x = (Screen.centerX + side * Screen.eyeDX) * size
        let y = (Screen.browY + drift) * size - lift

        Capsule(style: .continuous)
            .fill(glow)
            .frame(width: w, height: hBar)
            .opacity(0.65)
            .shadow(color: glow.opacity(0.6), radius: hBar * 0.8)
            .position(x: x, y: y)
    }

    // MARK: Mouth

    @ViewBuilder
    private func mouth(openness amp: CGFloat) -> some View {
        let openH = (0.010 + amp * 0.075) * size      // thin line → open aperture
        let w = (Screen.mouthMinW + (Screen.mouthMaxW - Screen.mouthMinW) * amp) * size
        let x = Screen.centerX * size
        let y = Screen.mouthY * size

        // A DARK opening: deep fill (darker than the screen glass) with a thin
        // cyan rim that lights up as it opens. Reads as a mouth, not a glow blob.
        ZStack {
            // Dark aperture body.
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.02, green: 0.03, blue: 0.10),
                            Color(red: 0.05, green: 0.09, blue: 0.22)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: w, height: openH)

            // Thin cyan rim — brightens with openness, gives a defined edge.
            Capsule(style: .continuous)
                .strokeBorder(glow.opacity(0.55 + 0.35 * Double(amp)),
                              lineWidth: max(1, size * 0.006))
                .frame(width: w, height: openH)
                .shadow(color: glow.opacity(0.35 + 0.25 * Double(amp)),
                        radius: size * 0.008)
        }
        .position(x: x, y: y)
    }

    // MARK: - Clock-driven state advance

    /// Eases the smoothed amplitude + speaking envelope toward the live values,
    /// and schedules blinks. Called each timeline tick.
    private func advance(now t: Double) {
        let dt = lastTick == 0 ? 0 : min(0.1, t - lastTick)
        // Seed the first blink relative to the absolute clock (t is
        // timeIntervalSinceReferenceDate, so a fixed seed would fire instantly).
        if lastTick == 0 { nextBlinkAt = t + 1.5 }
        lastTick = t

        // Exponential smoothing toward live amplitude. Mouth tracks fairly fast.
        let target = CGFloat(max(0, min(1, amplitude)))
        let mouthK = 1 - pow(0.001, dt)            // ~fast follow
        smoothedAmp += (target - smoothedAmp) * mouthK

        // Speaking envelope — slower, so brows don't jitter between syllables.
        let spkTarget: CGFloat = amplitude > 0.06 ? 1 : 0
        let spkK = 1 - pow(0.02, dt)               // ~slow
        speaking += (spkTarget - speaking) * spkK

        // Blink scheduling (driven off absolute clock so it's frame-independent).
        if blinkStart < 0 && t >= nextBlinkAt {
            blinkStart = t
        }
        if blinkStart >= 0 && t - blinkStart > 0.16 {
            blinkStart = -1
            // Next blink in 3.5–5.5s, varied via a cheap hash of the clock.
            let jitter = (sin(t * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
            nextBlinkAt = t + 3.5 + Double(abs(jitter)) * 2.0
        }
    }

    /// Returns the eye-open scale: 1 = open, ~0.08 = shut. A blink lasts ~110ms
    /// (down + up), modelled as a quick symmetric dip.
    private func blinkAmount(now t: Double) -> CGFloat {
        guard blinkStart >= 0 else { return 1 }
        let p = (t - blinkStart) / 0.11            // 0→1 over the blink window
        if p >= 1 { return 1 }
        // Triangle: shut at the midpoint.
        let tri = 1 - abs(p - 0.5) * 2             // 0→1→0
        return 1 - CGFloat(tri) * 0.92             // 1 → 0.08 → 1
    }

    // MARK: - Loading

    private static func loadBase() -> NSImage? {
        NSImage(named: "pulsar-base")
    }
}
