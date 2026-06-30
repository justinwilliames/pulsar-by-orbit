import SwiftUI

struct FloatingHeadsView: View {
    let viewModel: DashboardViewModel
    /// Shared geometry: which side the caption renders on + its horizontal nudge.
    let layout: FloatingLayoutModel

    /// Reports the caption's CURRENT (revealed) height up to the panel controller
    /// so it can grow the window in the locked direction as the text types in
    /// (0 when hidden).
    var onCaptionHeightChange: ((CGFloat) -> Void)?

    /// Reports the caption TEXT once per line so the controller can measure its
    /// full height DETERMINISTICALLY (AppKit) and size the panel to fit the whole
    /// line. Replaces the SwiftUI height feedback, which deadlocked and clipped
    /// long captions at ~3 lines.
    var onCaptionText: ((String) -> Void)?

    private let orbitRadius: CGFloat = 82
    private let thumbnailSize: CGFloat = 40
    private let orbitYOffset: CGFloat = 24
    private let arcStart: Double = 20
    private let arcEnd: Double = 160

    /// Fixed head-zone footprint. The head + its orbiting queue thumbnails + glow
    /// live here; the caption grows ABOVE or BELOW it. Height is sized so the
    /// pulsar-pulse glow (ripple frame = portrait+110 ⇒ ~115pt half-extent, plus
    /// the head's soft shadow + bob) fades COMPLETELY before the panel's edge —
    /// the head is centred, giving equal top/bottom clearance so neither
    /// placement (caption-below ⇒ head near top, caption-above ⇒ head near
    /// bottom) clips the glow. The caption still hugs the head via the negative
    /// attach gap below, so this headroom does NOT reopen an empty gap.
    static let headZoneWidth: CGFloat = 240
    static let headZoneHeight: CGFloat = 240

    /// Negative overlap so the caption tucks UNDER the head's lower glow tail and
    /// reads as attached — keeps the caption tight even though the head zone is
    /// tall enough to clear the glow.
    private let captionAttachGap: CGFloat = -22
    private let captionEdgePadding: CGFloat = 6

    // MARK: - Caption lifecycle state

    @State private var displayedCaption: String?
    @State private var lingerTask: Task<Void, Never>?
    /// When the current caption first appeared — drives the typewriter's local clock.
    @State private var captionStartedAt: Date?

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

    /// The drone category owning the current line, only when it's a real drone
    /// (not Pulsar / nil). Drives the speaker-switch + theming.
    private var activeDroneCategory: String? {
        let cat = viewModel.playback.currentAgentCategory
        return isDrone(cat) ? cat?.lowercased() : nil
    }

    /// When a drone is the active speaker, Pulsar shrinks and falls silent
    /// (amplitude 0); otherwise Pulsar is full-size and speaks.
    private var pulsarIsActive: Bool { activeDroneCategory == nil }

    @ViewBuilder
    private var headZone: some View {
        ZStack {
            if let voice = viewModel.playback.currentVoice {
                FloatingPortraitView(
                    voiceName: voice,
                    amplitude: pulsarIsActive ? viewModel.lipSync.amplitude : 0,
                    voiceColor: viewModel.voiceColor(for: voice),
                    portraitManager: viewModel.portraitManager
                )
                .id(voice)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
                // Speaker handoff: when a drone owns the line, Pulsar clearly
                // SHRINKS and RECEDES — small scale + dimmed opacity so it
                // visibly steps back and the eye goes to the active drone. Back
                // to full size + full opacity when it's Pulsar's line again.
                .scaleEffect(pulsarIsActive ? 1.0 : 0.48)
                .opacity(pulsarIsActive ? 1.0 : 0.55)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: pulsarIsActive)
                // Active drone pops in FRONT of a shrunken Pulsar, so it must
                // out-rank Pulsar's zIndex when speaking; Pulsar leads otherwise.
                .zIndex(pulsarIsActive ? 10 : 6)

                // In-flight sub-agent drones orbiting Pulsar — only the live
                // ones are present. The active speaker pops + lip-syncs.
                let drones = sortedDrones
                ForEach(Array(drones.enumerated()), id: \.element.id) { index, drone in
                    FloatingDronePortraitView(
                        category: drone.category,
                        isActiveSpeaker: drone.category == activeDroneCategory,
                        liveAmplitude: viewModel.lipSync.amplitude,
                        thumbnailSize: thumbnailSize,
                        orbitRadius: orbitRadius,
                        orbitYOffset: orbitYOffset,
                        angle: orbitAngle(index: index, total: drones.count),
                        index: index,
                        portraitManager: viewModel.portraitManager
                    )
                    .id(drone.id)
                    .zIndex(drone.category == activeDroneCategory ? 9 : Double(4 - index))
                }

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
                    .zIndex(Double(-1 - index))
                }
            }
        }
        .frame(width: Self.headZoneWidth, height: Self.headZoneHeight)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: viewModel.queueItems.map(\.id))
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: sortedDrones.map(\.id))
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: viewModel.playback.currentVoice)
    }

    /// In-flight drones in a stable order (by agentId) so orbit slots don't
    /// reshuffle every render.
    private var sortedDrones: [DroneInFlight] {
        viewModel.inFlightDrones
            .sorted { $0.key < $1.key }
            .map { DroneInFlight(id: $0.key, category: $0.value.lowercased()) }
    }

    // MARK: - Caption zone

    @ViewBuilder
    private var captionZone: some View {
        Group {
            if let caption = displayedCaption {
                SubtitleBubbleView(fullText: caption,
                                   startedAt: captionStartedAt ?? Date(),
                                   holdFull: !viewModel.playback.isPlaying,
                                   tailEdge: layout.captionEdge == .above ? .bottom : .top,
                                   maxHeight: captionMaxHeight,
                                   activeColor: droneColor(for: viewModel.playback.currentAgentCategory))
                    .overlay(alignment: .top) { droneNameCard }
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
            if let new { onCaptionText?(new) } else { onCaptionHeightChange?(0) }
        }
    }


    /// A small pill above the caption showing the active drone's name, tinted to
    /// its colour. Only shown when a drone owns the line; Pulsar shows nothing.
    @ViewBuilder
    private var droneNameCard: some View {
        if let category = activeDroneCategory {
            let color = droneColor(for: category)
            Text(category.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(color.opacity(0.85))
                )
                .overlay(
                    Capsule().stroke(color, lineWidth: 1).blur(radius: 1.5)
                )
                .shadow(color: color.opacity(0.5), radius: 4)
                .offset(y: -14)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                .allowsHitTesting(false)
        }
    }

    /// Cap the bubble height to what the panel can show on screen, so an extreme
    /// line still fits in full rather than being truncated.
    private var captionMaxHeight: CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        // Leave room for the head zone + comfortable top/bottom margins.
        return max(120, screenH - Self.headZoneHeight - 80)
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
            if displayedCaption != text { captionStartedAt = Date() }  // new line → restart the typewriter clock
            displayedCaption = text
        } else if let text = source, !text.isEmpty, displayedCaption != nil {
            displayedCaption = text
            scheduleLinger()
        } else if source == nil || source?.isEmpty == true {
            lingerTask?.cancel(); lingerTask = nil
            displayedCaption = nil
            captionStartedAt = nil
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

/// One in-flight sub-agent drone, identified by its agentId, with its category.
private struct DroneInFlight: Identifiable {
    let id: String        // agentId
    let category: String
}

/// Carries the caption's CURRENT (revealed) laid-out height to the controller.
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
