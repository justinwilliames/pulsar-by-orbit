import SwiftUI

/// PulsarMark — Orbit indigo squircle hosting a white waveform.path glyph.
/// Mirrors Comet's CometMark; use where a compact brand anchor is needed
/// (popover header, About view, etc.). Size is controlled by the caller's
/// `.frame()` modifier.
struct PulsarMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.265, style: .continuous)
                .fill(Color.orbit)
            Image(systemName: "waveform.path")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(size * 0.18)
        }
        .frame(width: size, height: size)
    }
}
