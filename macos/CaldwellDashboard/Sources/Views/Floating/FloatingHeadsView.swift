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
    /// Lift the whole orbit UP so the drones ring the TOP/sides of the central
    /// head, leaving the below-head zone clear for the name pill + subtitle.
    /// Kept modest so even the top-most of 6 slots (radius 82 + this lift + thumb
    /// half ≈ 108pt) clears the 120pt half-height without clipping.
    private let orbitYOffset: CGFloat = -6
    /// Upper arc, in SwiftUI screen degrees (y down): sweeps across the TOP and
    /// upper sides of the head (sin negative = above centre). Widened to 190°→350°
    /// so up to SIX distinct-type slots seat with a clean gap (step 32°, adjacent
    /// centres ≈ 45pt apart > the 40pt thumbnail) instead of overlapping.
    private let arcStart: Double = 190
    private let arcEnd: Double = 350

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The single source of truth for who is speaking (P3). Everything in the
    /// head zone reads ONLY this — no independent currentAgentCategory /
    /// inFlightDrones / amplitude reads — so the centre, name card, and subtitle
    /// can never desync.
    private var speaker: DashboardViewModel.SpeakerSnapshot? { viewModel.activeSpeaker }

    /// The drone category owning the line, or nil when Pulsar speaks.
    private var activeDroneCategory: String? { speaker?.category }

    /// The head zone renders whenever something is speaking OR a sub-agent is
    /// in-flight — so silently-running drones still hover around a calm, centred
    /// Pulsar (no lip-sync, no caption) until they despawn.
    private var panelHasContent: Bool {
        speaker != nil || viewModel.hasInFlightDrones
    }

    // MARK: - Head zone (true place-swap via matched arcs)

    @ViewBuilder
    private var headZone: some View {
        ZStack {
            if panelHasContent {
                // Idle queued voices orbit behind everything.
                queuedThumbnails

                // ONE list of participants: the centre occupant + one orbit slot
                // PER DISTINCT in-flight character TYPE (up to 6 types → 6 slots).
                // Each is positioned by its TARGET slot — centre or an orbit index
                // — so when the active speaker changes, the incoming type travels
                // orbit→centre while Pulsar travels centre→orbit on the SAME
                // spring value-change: a genuine pass-the-baton, not a crossfade.
                ForEach(participants) { p in
                    participantView(p)
                        .id(p.id)
                        .zIndex(p.isCentre ? 20 : Double(6 - p.orbitIndex))
                }
            }
        }
        .frame(width: Self.headZoneWidth, height: Self.headZoneHeight)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: viewModel.queueItems.map(\.id))
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: sortedDrones.map(\.id))
        // The swap itself, P1: arriving drone overshoots slightly into the
        // centre (presence); departing Pulsar eases out slower. Both keyed on
        // who holds the centre so they animate as a matched trade.
        .animation(.spring(response: 0.38, dampingFraction: 0.62), value: activeDroneCategory)
    }

    /// Render one participant in its current slot. The CENTRE occupant is the
    /// full-size Pulsar-style portrait (glow tinted to the speaker); ORBIT
    /// occupants are small drone thumbnails. Pulsar in orbit renders as a
    /// drone-sized pulsar thumbnail.
    @ViewBuilder
    private func participantView(_ p: Participant) -> some View {
        if p.isCentre {
            // MATCHED ARC (P1): the centre occupant ARRIVES from the orbit slot
            // it just vacated (insertion offset = that slot) and, when replaced,
            // DEPARTS toward the slot it's headed for — so the incoming drone and
            // the outgoing Pulsar physically pass each other rather than cross-
            // fading in place. Arriving overshoots slightly (presence); departing
            // eases out slower.
            let home = homeOrbitOffset(for: p)
            FloatingPortraitView(
                voiceName: speaker?.voiceLabel ?? "Pulsar",
                amplitude: speaker?.amplitude ?? 0,        // the centre is the speaker
                voiceColor: p.color,
                portraitManager: viewModel.portraitManager,
                droneName: p.category ?? "pulsar",
                glowColor: p.color
            )
            // The active type's count (×N) still reads in the centre slot.
            .overlay(alignment: .bottomTrailing) { countBadge(p.count, color: p.color, big: true) }
            // The speaker's name lives as a header pill on the subtitle bubble
            // (see `nameHeaderPill`), NOT under the chin — that zone is where the
            // orbit drones + the bubble sit and the card was getting occluded.
            .transition(.asymmetric(
                insertion: .offset(home)
                    .combined(with: .scale(scale: 0.72))   // steps forward from depth
                    .combined(with: .opacity)
                    .animation(.spring(response: 0.38, dampingFraction: 0.62)),
                removal: .offset(home)
                    .combined(with: .scale(scale: 0.72))
                    .combined(with: .opacity)
                    .animation(.spring(response: 0.55, dampingFraction: 0.74))
            ))
        } else {
            FloatingDronePortraitView(
                category: p.category ?? "pulsar",
                isActiveSpeaker: false,                    // the speaker is always centre
                liveAmplitude: 0,
                thumbnailSize: thumbnailSize,
                orbitRadius: orbitRadius,
                orbitYOffset: orbitYOffset,
                angle: orbitAngle(index: p.orbitIndex, total: orbitTypeSlots.count),
                index: p.orbitIndex,
                reduceMotion: reduceMotion,
                countBadge: p.count,
                portraitManager: viewModel.portraitManager
            )
        }
    }

    /// A small "×N" count badge for a character-type slot running N>1 drones.
    /// N==1 → nothing. Tinted to the type colour; legible on the dark desktop.
    @ViewBuilder
    private func countBadge(_ count: Int, color: Color, big: Bool) -> some View {
        if count > 1 {
            Text("×\(count)")
                .font(.system(size: big ? 12 : 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, big ? 6 : 5)
                .padding(.vertical, big ? 2.5 : 1.5)
                .background(Capsule().fill(color.opacity(0.95)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .allowsHitTesting(false)
        }
    }

    /// The orbit-slot offset the centre occupant travels FROM (on arrival) and
    /// TO (on departure) — the "swap lane". Both the incoming type and the
    /// outgoing Pulsar trade through the first orbit slot, so they pass each
    /// other along the same arc.
    private func homeOrbitOffset(for _: Participant) -> CGSize {
        let angle = orbitAngle(index: 0, total: max(orbitTypeSlots.count, 1))
        return CGSize(width: cos(angle) * orbitRadius,
                      height: sin(angle) * orbitRadius + orbitYOffset)
    }

    /// The speaker's identity as a tinted pill HEADER attached to the TOP edge of
    /// the subtitle bubble — "NAME · ROLE", themed to the speaker's colour, drawn
    /// above the orbit z-order. Co-locating it with the speech keeps the name
    /// legible and clear of the orbit drones that crowd the below-head zone.
    /// Shown only when a drone holds the line; Pulsar shows nothing.
    @ViewBuilder
    private var nameHeaderPill: some View {
        if let category = activeDroneCategory {
            let color = droneColor(for: category)
            let role = droneRole(for: category).uppercased()
            Text(role.isEmpty ? category.uppercased() : "\(category.uppercased()) · \(role)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(color.opacity(0.92)))
                // strokeBorder draws INSIDE the edge so a crisp 1pt line survives.
                .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                .shadow(color: color.opacity(0.6), radius: 8)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                .allowsHitTesting(false)
        }
    }

    /// Idle queued voices keep their existing orbiting thumbnails, behind the drones.
    @ViewBuilder
    private var queuedThumbnails: some View {
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

    // MARK: - Participant model (one slot per distinct character TYPE)

    /// One participant on screen: Pulsar or a character-TYPE slot (one per
    /// distinct in-flight category, however many drones of that type are
    /// running). Identity is stable — Pulsar = "pulsar", a type slot = its
    /// category name — so SwiftUI animates the SAME view between centre and orbit
    /// as the speaker swaps. `count` is how many drones of this type are in
    /// flight (>1 → a "×N" badge).
    private struct Participant: Identifiable {
        let id: String          // "pulsar" or the category name
        let category: String?   // nil = Pulsar
        let color: Color
        let count: Int          // in-flight drones of this type (1 = no badge)
        let isCentre: Bool
        let orbitIndex: Int     // valid only when !isCentre
    }

    /// The full participant list: exactly one centre occupant + one orbit slot
    /// PER DISTINCT in-flight character type.
    private var participants: [Participant] {
        var out: [Participant] = []
        let active = activeDroneCategory
        let counts = inFlightCountsByCategory

        // Centre occupant. When a drone is the ACTIVE SPEAKER its OWN face must
        // show — its frames + colour — even if that category is no longer in the
        // in-flight set (a sub-agent can finish, then the session narrates its
        // result tagged --agent <cat>). The centre is keyed by category so it's
        // continuous with that type's orbit slot through the swap. The count
        // still reflects how many of that type are running.
        if let active {
            out.append(Participant(id: active, category: active,
                                   color: droneColor(for: active),
                                   count: counts[active] ?? 1,
                                   isCentre: true, orbitIndex: 0))
        } else {
            out.append(Participant(id: "pulsar", category: nil,
                                   color: droneColor(for: nil),
                                   count: 1, isCentre: true, orbitIndex: 0))
        }

        // Orbit slots: one per distinct in-flight type (minus the centre type),
        // plus Pulsar (drone-sized) when a drone holds the centre.
        for (i, slot) in orbitTypeSlots.enumerated() {
            out.append(Participant(id: slot.id, category: slot.category,
                                   color: droneColor(for: slot.categoryKey),
                                   count: slot.count,
                                   isCentre: false, orbitIndex: i))
        }
        return out
    }

    /// One orbit slot per distinct character type.
    private struct OrbitTypeSlot: Identifiable {
        let id: String          // "pulsar" or the category name
        let category: String?   // nil = Pulsar
        let count: Int
        /// Colour/category key — "pulsar" for the Pulsar slot, else the category.
        var categoryKey: String { category ?? "pulsar" }
    }

    /// The orbit roster, grouped by TYPE: one slot per distinct in-flight
    /// category (excluding the one at centre), plus Pulsar pinned first when a
    /// drone holds the centre. Stable canonical order so slots don't reshuffle.
    private var orbitTypeSlots: [OrbitTypeSlot] {
        let counts = inFlightCountsByCategory
        var slots: [OrbitTypeSlot] = []
        let active = activeDroneCategory

        // Pulsar orbits (drone-sized) only while a drone holds the centre.
        if active != nil {
            slots.append(OrbitTypeSlot(id: "pulsar", category: nil, count: 1))
        }
        // One slot per distinct in-flight type, in canonical taxonomy order,
        // skipping the type that's currently at centre.
        for category in DroneRegistry.categories where category != active {
            if let count = counts[category], count > 0 {
                slots.append(OrbitTypeSlot(id: category, category: category, count: count))
            }
        }
        return slots
    }

    /// In-flight drone counts keyed by (lowercased) category.
    private var inFlightCountsByCategory: [String: Int] {
        var counts: [String: Int] = [:]
        for category in viewModel.inFlightDrones.values {
            counts[category.lowercased(), default: 0] += 1
        }
        return counts
    }

    /// In-flight drones in a stable order (by agentId) — kept for the swap-edge
    /// animation key (membership/category set).
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
                                   activeColor: speaker?.color ?? .orbitLight)   // P3 single source
                    // Speaker name pill straddling the bubble's TOP edge, above
                    // the orbit z-order so it's never occluded by a drone.
                    .overlay(alignment: .top) {
                        nameHeaderPill
                            .offset(y: layout.captionEdge == .above ? 6 : -10)
                            .zIndex(40)
                    }
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
