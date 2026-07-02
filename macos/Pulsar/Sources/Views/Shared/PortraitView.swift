import SwiftUI

/// Pulsar's animated portrait.
///
/// Blends 5 rendered frames of the robot — mouth closed (0) → full open (4) —
/// driven by `amplitude`. The amplitude is exponentially smoothed and mapped to
/// a continuous position across the frame strip; the two adjacent frames are
/// crossfaded by opacity, so the mouth appears to move continuously through the
/// rendered art rather than snapping between discrete frames.
///
/// A blink (`pulsar-blink`, eyes closed, eyebrows kept) is crossfaded over the
/// closed frame on a varied ~3.5–5.5s timer — but ONLY during speech pauses
/// (smoothed amplitude < 0.05), so the robot never blinks mid-sentence.
///
/// The whole portrait is clipped to a continuous-curvature *squircle* (not a
/// circle), with the amplitude glow stroke following the same squircle.
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
    /// Which frame set to load: `"<droneName>-mouth-0…4"` + `"<droneName>-blink"`.
    /// Defaults to "pulsar" so existing callers render Pulsar unchanged; a drone
    /// category (e.g. "voyager") swaps in that drone's frames.
    var droneName: String = "pulsar"

    /// The 5 rendered mouth frames, loaded once (closed → full open).
    @State private var frames: [NSImage]
    /// The blink frame (eyes closed). Optional — blink simply no-ops if absent.
    @State private var blinkFrame: NSImage?

    init(voiceName: String, amplitude: Float, size: CGFloat, voiceColor: Color,
         portraitManager: PortraitManager, droneName: String = "pulsar") {
        self.voiceName = voiceName
        self.amplitude = amplitude
        self.size = size
        self.voiceColor = voiceColor
        self.portraitManager = portraitManager
        self.droneName = droneName
        _frames = State(initialValue: PortraitView.loadFrames(droneName: droneName))
        let resolvedBlink = droneName == "unknown" ? "pulsar" : droneName
        _blinkFrame = State(initialValue: NSImage(named: "\(resolvedBlink)-blink"))
    }

    /// Exponentially-smoothed amplitude in 0…1, used to position across frames.
    @State private var smoothedAmp: CGFloat = 0
    @State private var lastTick: Double = 0

    // MARK: Blink state (driven off the timeline clock)
    @State private var nextBlinkAt: Double = 0       // seeded on first tick
    @State private var blinkStart: Double = -1       // -1 = not blinking

    /// A blink lasts ~120ms (down + up). Only fire when amplitude is below this.
    private let blinkDuration: Double = 0.12
    private let speechFloor: CGFloat = 0.05

    /// The portrait clip/stroke shape — a continuous-curvature squircle (rounded
    /// rect, iOS-style superellipse) rather than a hard circle. Corner radius
    /// scales with `size` so it reads identically at any portrait dimension.
    private var squircle: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let blink = blinkAmount(now: t)            // 0…1 overlay opacity

            ZStack {
                if frames.count == 5 {
                    frameStack(at: smoothedAmp)

                    // Blink overlay — the eyes-closed frame faded in briefly over
                    // the (closed) mouth frame during a pause.
                    if let blinkFrame, blink > 0 {
                        Image(nsImage: blinkFrame)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .opacity(blink)
                    }
                } else {
                    fallback
                }
            }
            .frame(width: size, height: size)
            .clipShape(squircle)
            .overlay {
                if amplitude > 0 {
                    squircle
                        .stroke(voiceColor.opacity(0.6), lineWidth: 2)
                        .shadow(color: voiceColor.opacity(0.4), radius: 6)
                }
            }
            .onChange(of: timeline.date) { _, _ in
                advance(now: t)
            }
            // The frames are seeded once in init from `droneName`; @State keeps
            // them across prop changes, so a view whose droneName flips (the centre
            // going Pulsar→drone, or a recycled slot) would otherwise keep the OLD
            // face. Reload on any droneName change so the head always matches.
            .onChange(of: droneName) { _, newName in
                frames = PortraitView.loadFrames(droneName: newName)
                let resolvedBlink = newName == "unknown" ? "pulsar" : newName
                blinkFrame = NSImage(named: "\(resolvedBlink)-blink")
                // Reset blink state so an in-flight blink from the previous face
                // doesn't fire over the incoming portrait. Defer the next blink
                // past the swap window (~0.5s) so the eye-open frame settles first.
                blinkStart = -1
                let now = Date().timeIntervalSinceReferenceDate
                nextBlinkAt = now + 0.5 + Double.random(in: 3.5...5.0)
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
        squircle
            .fill(voiceColor.opacity(0.3))
            .overlay {
                Text(String(voiceName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(voiceColor)
            }
    }

    // MARK: - Drive

    /// Eases the smoothed amplitude toward the live value each timeline tick, so
    /// the crossfade glides instead of stepping with raw amplitude updates. Also
    /// schedules blinks — but only during pauses, never mid-speech.
    private func advance(now t: Double) {
        let dt = lastTick == 0 ? 0 : min(0.1, t - lastTick)
        // Seed the first blink relative to the absolute clock (t is huge, so a
        // fixed seed would fire instantly).
        if lastTick == 0 { nextBlinkAt = t + Double.random(in: 3.5...5.5) }
        lastTick = t

        let target = CGFloat(max(0, min(1, amplitude)))
        let k = 1 - pow(0.001, dt)        // fast but smooth follow
        smoothedAmp += (target - smoothedAmp) * k

        // Start a blink only in a pause (low amplitude) once the timer elapses.
        if blinkStart < 0 && t >= nextBlinkAt && smoothedAmp < speechFloor {
            blinkStart = t
        }
        // End the blink and schedule the next, varied so it isn't metronomic.
        if blinkStart >= 0 && t - blinkStart > blinkDuration {
            blinkStart = -1
            nextBlinkAt = t + Double.random(in: 3.5...5.5)
        }
        // If the timer elapsed while speaking, keep pushing it out so the blink
        // lands in the next genuine pause rather than the instant speech stops.
        if blinkStart < 0 && t >= nextBlinkAt && smoothedAmp >= speechFloor {
            nextBlinkAt = t + 0.4
        }
    }

    /// Blink overlay opacity, 0…1. A quick symmetric in/out triangle over
    /// `blinkDuration` so the eyes-closed frame flashes briefly and fades.
    private func blinkAmount(now t: Double) -> Double {
        guard blinkStart >= 0 else { return 0 }
        let p = (t - blinkStart) / blinkDuration       // 0…1 over the blink
        if p <= 0 || p >= 1 { return 0 }
        return 1 - abs(p - 0.5) * 2                     // 0 → 1 → 0
    }

    // MARK: - Loading

    /// Loads `<droneName>-mouth-0…4` from the bundle. Returns an empty array if
    /// any frame is missing, which triggers the fallback monogram.
    ///
    /// `"unknown"` has no portrait art — it maps to the `"pulsar"` frame set so
    /// the swarm renders a real neutral face instead of a broken monogram.
    private static func loadFrames(droneName: String = "pulsar") -> [NSImage] {
        let name = droneName == "unknown" ? "pulsar" : droneName
        var out: [NSImage] = []
        for i in 0..<5 {
            guard let img = NSImage(named: "\(name)-mouth-\(i)") else { return [] }
            out.append(img)
        }
        return out
    }
}
