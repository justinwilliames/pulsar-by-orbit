import SwiftUI

struct FloatingHeadsView: View {
    let viewModel: DashboardViewModel
    /// Shared geometry: which side the caption renders on + its horizontal nudge.
    let layout: FloatingLayoutModel

    /// Reports the caption's measured height (0 when hidden) up to the panel
    /// controller so it can grow the window on the correct side and shrink back.
    var onCaptionHeightChange: ((CGFloat) -> Void)?

    private let orbitRadius: CGFloat = 70
    private let thumbnailSize: CGFloat = 40
    private let orbitYOffset: CGFloat = 24
    private let arcStart: Double = 30
    private let arcEnd: Double = 150

    /// Fixed head-zone footprint. The head + its orbiting queue thumbnails + glow
    /// live here; the caption grows ABOVE or BELOW it. Tightened from the old
    /// 240×260 so the caption hugs the VISIBLE head rather than floating below a
    /// tall empty zone. Kept in sync with `FloatingPanelController.headZoneSize`.
    static let headZoneWidth: CGFloat = 240
    static let headZoneHeight: CGFloat = 200

    /// Small overlap so the caption visually attaches to the head instead of
    /// leaving an air gap. The head's glow tail fades within the zone, so a
    /// slight negative gap reads as "attached".
    private let captionAttachGap: CGFloat = -4
    private let captionEdgePadding: CGFloat = 6

    // MARK: - Caption lifecycle state

    @State private var displayedCaption: String?
    @State private var lingerTask: Task<Void, Never>?

    /// Linger ~10s after a line completes so there's time to finish reading.
    static let lingerAfterIdle: TimeInterval = 10.0

    var body: some View {
        VStack(spacing: captionAttachGap) {
            if layout.captionEdge == .above {
                captionZone
                headZone
            } else {
                headZone
                captionZone
            }
        }
        .frame(width: Self.headZoneWidth)
        .frame(maxHeight: .infinity, alignment: layout.captionEdge == .above ? .bottom : .top)
        .onChange(of: captionSource) { _, _ in updateCaption() }
        .onChange(of: viewModel.playback.isPlaying) { _, _ in updateCaption() }
        .onChange(of: subtitlesActive) { _, _ in updateCaption() }
        .onAppear { updateCaption() }
    }

    // MARK: - Head zone

    @ViewBuilder
    private var headZone: some View {
        ZStack {
            if let voice = viewModel.playback.currentVoice {
                FloatingPortraitView(
                    voiceName: voice,
                    amplitude: viewModel.lipSync.amplitude,
                    voiceColor: viewModel.voiceColor(for: voice),
                    portraitManager: viewModel.portraitManager
                )
                .id(voice)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
                .offset(y: -8)
                .zIndex(10)

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
        .frame(width: Self.headZoneWidth, height: Self.headZoneHeight)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: viewModel.queueItems.map(\.id))
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: viewModel.playback.currentVoice)
    }

    // MARK: - Caption zone

    @ViewBuilder
    private var captionZone: some View {
        Group {
            if let caption = displayedCaption {
                SubtitleBubbleView(text: caption,
                                   tailEdge: layout.captionEdge == .above ? .bottom : .top)
                    .id(caption)
                    .offset(x: layout.captionXOffset)
                    .padding(.horizontal, captionEdgePadding)
                    .padding(layout.captionEdge == .above ? .top : .bottom, captionEdgePadding)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: CaptionHeightKey.self, value: proxy.size.height)
                        }
                    )
                    .transition(.opacity.combined(
                        with: .move(edge: layout.captionEdge == .above ? .bottom : .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.35), value: displayedCaption)
        .animation(.easeInOut(duration: 0.35), value: layout.captionEdge)
        .onPreferenceChange(CaptionHeightKey.self) { height in
            onCaptionHeightChange?(displayedCaption == nil ? 0 : height)
        }
        .onChange(of: displayedCaption) { _, new in
            if new == nil { onCaptionHeightChange?(0) }
        }
    }

    // MARK: - Caption lifecycle driver

    private var captionSource: String? { viewModel.playback.currentText }

    private var subtitlesActive: Bool {
        viewModel.isSubtitlesEnabled && viewModel.isFloatingHeadEnabled
    }

    private func updateCaption() {
        guard subtitlesActive else {
            lingerTask?.cancel(); lingerTask = nil
            displayedCaption = nil
            return
        }

        let source = captionSource
        let speaking = viewModel.playback.isPlaying

        if speaking, let text = source, !text.isEmpty {
            lingerTask?.cancel(); lingerTask = nil
            displayedCaption = text
        } else if let text = source, !text.isEmpty, displayedCaption != nil {
            displayedCaption = text
            scheduleLinger()
        } else if source == nil || source?.isEmpty == true {
            lingerTask?.cancel(); lingerTask = nil
            displayedCaption = nil
        }
    }

    private func scheduleLinger() {
        lingerTask?.cancel()
        lingerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.lingerAfterIdle * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if !viewModel.playback.isPlaying {
                displayedCaption = nil
            }
        }
    }

    private func orbitAngle(index: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        if total == 1 { return ((arcStart + arcEnd) / 2) * .pi / 180 }
        let span = arcEnd - arcStart
        let step = span / Double(total - 1)
        let degrees = arcStart + step * Double(index)
        return degrees * .pi / 180
    }
}

/// Carries the caption's laid-out height up to the panel controller.
private struct CaptionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
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
