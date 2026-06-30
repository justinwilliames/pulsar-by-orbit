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
    /// Which speaker produced the currently-displayed caption. A caption belongs
    /// to ONE speaker; if the active speaker changes (or goes idle), the old
    /// caption is cleared rather than lingered under a different/idle speaker.
    @State private var captionOwner: String?

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
        .onChange(of: currentSpeakerKey) { _, _ in updateCaption() }
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

    /// The head zone renders only while something is actually speaking (the panel
    /// is speech-gated). In-flight drones still drive the orbit/swarm WHILE the
    /// panel is up, but a non-empty in-flight set alone never renders a silent,
    /// speaker-less head zone — drones appear only when they have something to say.
    private var panelHasContent: Bool {
        speaker != nil
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
    /// full-size speaker portrait (glow tinted to the speaker — Pulsar or a
    /// drone); ORBIT occupants are small drone thumbnails (never Pulsar).
    @ViewBuilder
    private func participantView(_ p: Participant) -> some View {
        if p.isCentre {
            // MATCHED ARC: an incoming drone ARRIVES from an orbit slot
            // (insertion offset = that slot) and, when the next speaker takes
            // over, DEPARTS toward an orbit slot — so consecutive drone speakers
            // pass each other rather than cross-fading in place. A Pulsar centre
            // simply fades in/out (he has no orbit slot to travel from/to).
            // Arriving overshoots slightly (presence); departing eases out slower.
            let home = homeOrbitOffset(for: p)
            FloatingPortraitView(
                voiceName: speaker?.voiceLabel ?? "Pulsar",
                amplitude: speaker?.amplitude ?? 0,        // the centre is the speaker
                voiceColor: p.color,
                portraitManager: viewModel.portraitManager,
                droneName: p.category ?? "pulsar",
                glowColor: p.color
            )
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
                portraitManager: viewModel.portraitManager
            )
        }
    }

    /// The orbit-slot offset the centre occupant travels FROM (on arrival) and
    /// TO (on departure) — the "swap lane" for drone↔drone hand-offs, so the
    /// incoming and outgoing drones pass each other along the same arc. (A Pulsar
    /// centre ignores this and just fades, having no orbit slot.)
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
    /// distinct in-flight category — the drones are CHARACTERS, so multiple
    /// sub-agents of a type still show as ONE busy character, never a count).
    /// Identity is stable — Pulsar = "pulsar", a type slot = its category name —
    /// so SwiftUI animates the SAME view between centre and orbit as the speaker
    /// swaps.
    private struct Participant: Identifiable {
        let id: String          // "pulsar" or the category name
        let category: String?   // nil = Pulsar
        let color: Color
        let isCentre: Bool
        let orbitIndex: Int     // valid only when !isCentre
    }

    /// The full participant list: the centre occupant (the ACTIVE SPEAKER —
    /// Pulsar OR a drone) + one orbit slot per OTHER distinct in-flight drone.
    /// Pulsar is a peer: he occupies the centre only when he's the speaker, and
    /// is never placed in the orbit.
    private var participants: [Participant] {
        var out: [Participant] = []
        let active = activeDroneCategory

        // Centre occupant = the active speaker. A drone's OWN face shows (its
        // frames + colour) even if its category is no longer in the in-flight set
        // (a sub-agent can finish, then the session narrates its result tagged
        // --agent <cat>). nil category = Pulsar speaks an untagged line.
        if let active {
            out.append(Participant(id: active, category: active,
                                   color: droneColor(for: active),
                                   isCentre: true, orbitIndex: 0))
        } else {
            out.append(Participant(id: "pulsar", category: nil,
                                   color: droneColor(for: nil),
                                   isCentre: true, orbitIndex: 0))
        }

        // Orbit slots: one per distinct in-flight DRONE type EXCEPT the centre
        // speaker. Pulsar never appears in orbit.
        for (i, slot) in orbitTypeSlots.enumerated() {
            out.append(Participant(id: slot.id, category: slot.category,
                                   color: droneColor(for: slot.categoryKey),
                                   isCentre: false, orbitIndex: i))
        }
        return out
    }

    /// One orbit slot per distinct in-flight DRONE type. Pulsar is NEVER in the
    /// orbit — he's a peer who only ever occupies the centre, and only as the
    /// active speaker.
    private struct OrbitTypeSlot: Identifiable {
        let id: String          // the category name
        let category: String    // always a real drone category
        var categoryKey: String { category }
    }

    /// The orbit roster, grouped by TYPE: one slot per distinct in-flight DRONE
    /// category, EXCLUDING the one at centre. Pulsar never appears here. Stable
    /// canonical order so slots don't reshuffle. Presence = "that type is
    /// working"; count is invisible by design (one character per type).
    ///
    /// So: a drone speaking → orbit = the OTHER in-flight drones (no Pulsar);
    /// Pulsar speaking → orbit = all in-flight drones; one drone alone → no orbit.
    private var orbitTypeSlots: [OrbitTypeSlot] {
        let present = inFlightCategories
        let active = activeDroneCategory
        return DroneRegistry.categories
            .filter { $0 != active && present.contains($0) }
            .map { OrbitTypeSlot(id: $0, category: $0) }
    }

    /// The set of distinct in-flight categories (lowercased) — presence only.
    private var inFlightCategories: Set<String> {
        Set(viewModel.inFlightDrones.values.map { $0.lowercased() })
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

    /// A stable identity for the CURRENT speaker — the drone category, else
    /// "pulsar" while Pulsar speaks, else nil when nothing is the active speaker.
    /// Used to detect a speaker CHANGE so a caption is never lingered under a
    /// different speaker.
    private var currentSpeakerKey: String? {
        guard let s = viewModel.activeSpeaker else { return nil }
        return s.category ?? "pulsar"
    }

    private var subtitlesActive: Bool {
        viewModel.isSubtitlesEnabled && viewModel.isFloatingHeadEnabled
    }

    private func updateCaption() {
        guard subtitlesActive else {
            clearCaption()
            return
        }

        let source = captionSource
        let speaking = viewModel.playback.isPlaying
        let owner = currentSpeakerKey

        // Speaker changed out from under a displayed caption → drop it at once.
        // The old caption belongs to the previous speaker, not whoever is here
        // now (or to the idle state). Don't linger it.
        if displayedCaption != nil, owner != captionOwner {
            clearCaption()
        }

        if speaking, let text = source, !text.isEmpty {
            lingerTask?.cancel(); lingerTask = nil
            if displayedCaption != text { captionStartedAt = Date() }  // new line → restart the typewriter clock
            displayedCaption = text
            captionOwner = owner
        } else if let text = source, !text.isEmpty, displayedCaption != nil, owner == captionOwner {
            // Same speaker, line finished → hold through the linger.
            displayedCaption = text
            scheduleLinger(for: owner)
        } else if source == nil || source?.isEmpty == true {
            clearCaption()
        }
    }

    /// Clear the caption + its lifecycle state in one place.
    private func clearCaption() {
        lingerTask?.cancel(); lingerTask = nil
        displayedCaption = nil
        captionStartedAt = nil
        captionOwner = nil
    }

    private func scheduleLinger(for owner: String?) {
        lingerTask?.cancel()
        lingerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.lingerAfterIdle * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Only clear if the SAME speaker is still (not) speaking — a new
            // speaker would have already replaced the caption + owner.
            if !viewModel.playback.isPlaying, captionOwner == owner {
                clearCaption()
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
