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
        static let eyeY: CGFloat    = 0.405   // eye row
        static let mouthY: CGFloat  = 0.478   // mouth centre, lower screen
        static let browY: CGFloat   = 0.352   // brow row, just above eyes (rest)
        static let eyeDX: CGFloat   = 0.094   // half-distance between eyes
        static let eyeW: CGFloat    = 0.078   // eye width
        static let eyeH: CGFloat    = 0.096   // eye height (open)
        static let browW: CGFloat   = 0.084   // brow bar length
        static let mouthMaxW: CGFloat = 0.250 // mouth width when fully open
        static let mouthMinW: CGFloat = 0.150 // mouth width when closed (line)
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
        let w = Screen.eyeW * size
        let h = Screen.eyeH * size
        let x = (Screen.centerX + side * Screen.eyeDX) * size
        let y = (Screen.eyeY + drift) * size

        ZStack {
            // Soft outer halo
            RoundedRectangle(cornerRadius: w * 0.5, style: .continuous)
                .fill(glow)
                .frame(width: w * 1.25, height: h * 1.25)
                .blur(radius: w * 0.45)
                .opacity(0.55)

            // Eye body — vertical gradient indigo→cyan
            RoundedRectangle(cornerRadius: w * 0.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [deep, glow],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: w, height: h)
                .shadow(color: glow.opacity(0.9), radius: h * 0.32)

            // Bright core highlight
            RoundedRectangle(cornerRadius: w * 0.45, style: .continuous)
                .fill(core)
                .frame(width: w * 0.5, height: h * 0.5)
                .blur(radius: w * 0.12)
                .opacity(0.95)
                .offset(y: -h * 0.12)
        }
        .scaleEffect(x: 1.0, y: max(0.08, blink), anchor: .center)
        .position(x: x, y: y)
    }

    // MARK: Brows

    @ViewBuilder
    private func brow(side: CGFloat, speaking: CGFloat, drift: CGFloat) -> some View {
        let w = Screen.browW * size
        let hBar = max(2.5, size * 0.018)

        // Lift up + small inward tilt when speaking. Kept small so the brow
        // stays on the dark glass and never rides up onto the silver frame.
        let lift = speaking * size * 0.014
        let tilt = Angle(degrees: Double(side) * -11 * Double(speaking)) // inner end up
        let x = (Screen.centerX + side * Screen.eyeDX) * size
        let y = (Screen.browY + drift) * size - lift

        ZStack {
            // Soft halo so the brow reads as its own glowing element.
            Capsule(style: .continuous)
                .fill(glow)
                .frame(width: w, height: hBar * 1.5)
                .blur(radius: hBar * 0.7)
                .opacity(0.45)
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: [deep, glow], startPoint: .leading, endPoint: .trailing))
                .frame(width: w, height: hBar)
                .shadow(color: glow.opacity(0.9), radius: hBar * 1.0)
        }
        .rotationEffect(tilt, anchor: .center)
        .position(x: x, y: y)
    }

    // MARK: Mouth

    @ViewBuilder
    private func mouth(openness amp: CGFloat) -> some View {
        let openH = (0.012 + amp * 0.085) * size      // line → wide aperture
        let w = (Screen.mouthMinW + (Screen.mouthMaxW - Screen.mouthMinW) * amp) * size
        let x = Screen.centerX * size
        let y = Screen.mouthY * size

        ZStack {
            // Soft outer glow halo
            Capsule(style: .continuous)
                .fill(glow)
                .frame(width: w * 1.1, height: openH * 1.6 + size * 0.01)
                .blur(radius: size * 0.022)
                .opacity(0.5)

            // Aperture body
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [glow, deep],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: w, height: openH)
                .shadow(color: glow.opacity(0.9), radius: openH * 0.6 + 2)

            // Bright inner core (grows with openness)
            Capsule(style: .continuous)
                .fill(core)
                .frame(width: w * 0.82, height: openH * 0.5)
                .blur(radius: openH * 0.18 + 0.5)
                .opacity(0.85 * Double(0.5 + 0.5 * amp))

            // Faint vocal centre-line — a thin bright bar across the mouth.
            Capsule()
                .fill(core)
                .frame(width: w * 0.9, height: max(1, size * 0.004))
                .opacity(0.6)
                .blur(radius: 0.5)
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
