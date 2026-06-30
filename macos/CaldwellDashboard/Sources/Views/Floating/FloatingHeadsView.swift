import SwiftUI

struct FloatingHeadsView: View {
    let viewModel: DashboardViewModel

    /// Reports the view's desired total height (head zone + caption, when shown)
    /// up to the panel controller so it can grow/shrink the window downward.
    var onContentHeightChange: ((CGFloat) -> Void)?

    private let orbitRadius: CGFloat = 70
    private let thumbnailSize: CGFloat = 40
    private let orbitYOffset: CGFloat = 24
    private let arcStart: Double = 30
    private let arcEnd: Double = 150

    /// Fixed head zone — the original 240×260 panel footprint. The head and its
    /// orbiting queue thumbnails live here; the caption grows BELOW it.
    private let headZoneWidth: CGFloat = 240
    private let headZoneHeight: CGFloat = 260
    /// Gap between the bottom of the head zone and the top of the caption.
    private let captionTopGap: CGFloat = 2
    private let captionBottomPadding: CGFloat = 10

    // MARK: - Caption lifecycle state
    //
    // currentText is HELD by PlaybackState after audio ends (see PlaybackState),
    // so we can linger on the last line, then fade out and clear it. A new line
    // arriving while one is showing cross-fades via the .id-keyed transition.

    /// The caption text currently being displayed (nil = hidden).
    @State private var displayedCaption: String?
    /// Pending linger timer — cancelled if a new line arrives during the linger.
    @State private var lingerTask: Task<Void, Never>?

    private static let lingerAfterIdle: TimeInterval = 1.5

    var body: some View {
        VStack(spacing: captionTopGap) {
            headZone
                .frame(width: headZoneWidth, height: headZoneHeight)

            captionZone
        }
        .frame(width: headZoneWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            // Measure total laid-out height and report it up to the panel.
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            onContentHeightChange?(height)
        }
        .onChange(of: captionSource) { _, _ in updateCaption() }
        .onChange(of: subtitlesActive) { _, _ in updateCaption() }
        .onAppear { updateCaption() }
    }

    // MARK: - Head zone (unchanged behaviour)

    @ViewBuilder
    private var headZone: some View {
        ZStack {
            if let voice = viewModel.playback.currentVoice {
                // Active speaker — Caldwell is the only voice, no label needed
                FloatingPortraitView(
                    voiceName: voice,
                    amplitude: viewModel.lipSync.amplitude,
                    voiceColor: viewModel.voiceColor(for: voice),
                    portraitManager: viewModel.portraitManager
                )
                .id(voice)
                // Clean on-brand entrance: scale up + fade in. The head's own
                // Pulsar pulse (FloatingPortraitView) fires immediately on
                // appear, so the indigo "ping" reads as the arrival beat.
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
                .offset(y: -16)
                .zIndex(10)

                // Orbiting queue thumbnails
                let queued = Array(viewModel.queueItems.filter { !$0.isPlaying }.prefix(5))
                ForEach(Array(queued.enumerated()), id: \.element.id) { index, item in
                    QueueBubbleView(
                        item: item,
                        index: index,
                        total: queued.count,
                        thumbnailSize: thumbnailSize,
                        orbitRadius: orbitRadius,
                        orbitYOffset: orbitYOffset,
                        angle: orbitAngle(index: index, total: queued.count),
                        voiceColor: viewModel.voiceColor(for: item.voice),
                        portraitManager: viewModel.portraitManager
                    )
                    .zIndex(Double(5 - index))
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: viewModel.queueItems.map(\.id))
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: viewModel.playback.currentVoice)
    }

    // MARK: - Caption zone (grows below the head)

    @ViewBuilder
    private var captionZone: some View {
        Group {
            if let caption = displayedCaption {
                SubtitleBubbleView(text: caption)
                    .id(caption)               // new text => cross-fade transition
                    .padding(.bottom, captionBottomPadding)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: displayedCaption)
    }

    // MARK: - Caption lifecycle driver

    /// The raw line PlaybackState currently holds (held through the idle tail).
    private var captionSource: String? {
        viewModel.playback.currentText
    }

    /// Whether subtitles should be shown at all: setting on AND head on. The
    /// head being off means the panel never appears, but guard anyway.
    private var subtitlesActive: Bool {
        viewModel.isSubtitlesEnabled && viewModel.isFloatingHeadEnabled
    }

    /// Reconciles the displayed caption against the live source + speaking state.
    /// - While speaking with text: show it immediately (cross-fades on change).
    /// - When speech ends (text still held): linger, then fade out and clear.
    /// - Subtitles off / head off: clear at once.
    private func updateCaption() {
        guard subtitlesActive else {
            lingerTask?.cancel()
            lingerTask = nil
            displayedCaption = nil
            return
        }

        let source = captionSource
        let speaking = viewModel.playback.isPlaying

        if speaking, let text = source, !text.isEmpty {
            // Live line — cancel any linger and show it now.
            lingerTask?.cancel()
            lingerTask = nil
            displayedCaption = text
        } else if let text = source, !text.isEmpty, displayedCaption != nil {
            // Audio finished but text is still held — keep the last line on
            // screen for the linger window, then fade out and clear.
            displayedCaption = text
            scheduleLinger()
        } else if source == nil || source?.isEmpty == true {
            // Source cleared (panel hidden / fully reset) — drop the caption.
            lingerTask?.cancel()
            lingerTask = nil
            displayedCaption = nil
        }
    }

    private func scheduleLinger() {
        lingerTask?.cancel()
        lingerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.lingerAfterIdle * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Only clear if still idle (a new line may have started).
            if !viewModel.playback.isPlaying {
                displayedCaption = nil
            }
        }
    }

    private func orbitAngle(index: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        if total == 1 {
            return ((arcStart + arcEnd) / 2) * .pi / 180
        }
        let span = arcEnd - arcStart
        let step = span / Double(total - 1)
        let degrees = arcStart + step * Double(index)
        return degrees * .pi / 180
    }
}

/// Carries the laid-out content height up to the panel controller.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 260
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Queue Bubble

struct QueueBubbleView: View {
    let item: QueueItem
    let index: Int
    let total: Int
    let thumbnailSize: CGFloat
    let orbitRadius: CGFloat
    let orbitYOffset: CGFloat
    let angle: Double
    let voiceColor: Color
    let portraitManager: PortraitManager

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = Double(index) * 1.7
            let bobX = sin(time * 0.9 + phase) * 2.0
            let bobY = cos(time * 0.7 + phase * 0.6) * 1.5

            PortraitView(
                voiceName: item.voice,
                amplitude: 0,
                size: thumbnailSize,
                voiceColor: voiceColor,
                portraitManager: portraitManager
            )
            .shadow(color: voiceColor.opacity(0.3), radius: 4)
            .scaleEffect(index == 0 ? 1.05 : 1.0)
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
                removal: .scale(scale: 1.4)
                    .combined(with: .opacity)
                    .combined(with: .offset(y: -60))
            )
        )
    }
}
