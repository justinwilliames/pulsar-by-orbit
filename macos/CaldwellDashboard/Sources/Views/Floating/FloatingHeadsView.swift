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

    private let orbitRadius: CGFloat = 80
    /// In-action sub-agent thumbnail size — bumped ~30% (40→52) so the swarm reads
    /// bold, not compressed. The cluster spacing + arc step below scale with it.
    private let thumbnailSize: CGFloat = 52
    /// Lift the whole cluster UP so the swarm hovers over the TOP of the hub,
    /// leaving the below-head zone clear for the name pill + subtitle.
    private let orbitYOffset: CGFloat = -8
    /// The swarm CLUSTERS above the hub rather than fanning across a wide rail:
    /// slots are placed symmetrically around a hub angle (270° = straight up)
    /// with a TIGHT per-slot angular step, so they group as a compact pod. The
    /// per-drone organic drift (FloatingDronePortraitView) then keeps them
    /// mingling so they never read as rigid, evenly-spaced icons.
    private let clusterCenterDegrees: Double = 270   // straight up
    /// Angular gap between adjacent swarm slots while a speaker holds the centre
    /// (the arc orbit). Widened to 44° so the larger 52pt thumbnails still clear
    /// each other on the arc.
    private let clusterStepDegrees: Double = 44
    /// Grid spacing for the IDLE symmetric cluster (no speaker) — sized to the
    /// larger 52pt thumbnails (~10pt gap) so they sit snug as one oval pod without
    /// the heads overlapping.
    private let clusterSpacing: CGFloat = 63

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

    /// Vertical overlap between the head zone and the caption. The head squircle
    /// (120pt) is centred in the 240pt head zone, so its BOTTOM sits ~60pt above
    /// the head zone's lower edge. This negative gap pulls the caption up so the
    /// bubble's tail nearly touches the squircle bottom, leaving only a few px —
    /// while still reserving `glowMargin` (via captionEdgePadding) so neither
    /// glow hard-cuts. −54 ⇒ tail ~6px below the squircle after the padding.
    private let captionAttachGap: CGFloat = -54
    /// Padding around the caption inside the panel — sized to the bubble's glow
    /// reserve so the outer glow fades fully before the panel edge (top/bottom +
    /// the horizontal side that the tail edge doesn't consume).
    private var captionEdgePadding: CGFloat { SubtitleBubbleView.glowMargin }

    // MARK: - Caption lifecycle state

    @State private var displayedCaption: String?
    @State private var lingerTask: Task<Void, Never>?
    /// When the current caption first appeared — drives the typewriter's local clock.
    @State private var captionStartedAt: Date?
    /// Which speaker produced the currently-displayed caption. A caption belongs
    /// to ONE speaker; if the active speaker changes (or goes idle), the old
    /// caption is cleared rather than lingered under a different/idle speaker.
    @State private var captionOwner: String?

    /// How long the caption stays after a line completes. Set deliberately LONGER
    /// than AppDelegate.tailAfterIdle (5s) + the panel's 0.9s fade, so the subtitle
    /// stays visible right through the head's fade-out and dissolves WITH it —
    /// rather than snapping out the instant the fade begins (which read as the head
    /// hovering subtitle-less). The panel's alpha fade carries the caption away
    /// before this timer ever clears the text.
    static let lingerAfterIdle: TimeInterval = 6.0

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

    /// The head zone renders while ANY participant is present — the live team
    /// (Pulsar + running sub-agents), whether or not anyone is currently
    /// speaking. Activity-gated: a running sub-agent (or an active main session)
    /// shows its participant orbiting even when silent; the centre is filled by
    /// whoever is speaking, or stays empty between lines if no one is.
    private var panelHasContent: Bool {
        speaker != nil || viewModel.hasInFlightDrones || viewModel.pulsarIsPresent
    }

    // MARK: - Head zone (true place-swap via matched arcs)

    @ViewBuilder
    private var headZone: some View {
        ZStack {
            if panelHasContent {
                // Idle queued voices orbit behind everything — but ONLY when there
                // is no live drone swarm. Once real drones are in flight, the
                // participant orbit is the sole representation of who's working; a
                // background queue-preview thumbnail then reads as a spurious drone
                // "hiding" behind the swarm. Suppress it whenever drones are present.
                if !viewModel.hasInFlightDrones {
                    queuedThumbnails
                }

                // ONE list of participants — the live team (Pulsar + running
                // sub-agents). CENTRE = the current speaker; ORBIT = everyone else
                // present (drones + present-but-silent Pulsar). Each is positioned
                // by its TARGET slot — centre or an orbit index — so when the
                // speaker changes, the incoming participant travels orbit→centre
                // and the outgoing one travels centre→orbit on the SAME spring
                // value-change: a genuine pass-the-baton, not a crossfade.
                ForEach(participants) { p in
                    ParticipantSlotView(
                        participant: p,
                        speaker: speaker,
                        orbitOffset: slotOffset(index: p.orbitIndex, total: orbitSlotCount),
                        thumbnailSize: thumbnailSize,
                        reduceMotion: reduceMotion,
                        portraitManager: viewModel.portraitManager
                    )
                    .id(p.id)
                    .zIndex(p.isCentre ? 20 : Double(7 - p.orbitIndex))
                }
            }
        }
        .frame(width: Self.headZoneWidth, height: Self.headZoneHeight)
        // [FIX 3 — Reduce Motion] All slot-glide springs are gated on
        // `reduceMotion`. When on, animations are nil (instant snap) so
        // participants teleport rather than spring — no vestibular motion.
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78), value: viewModel.queueItems.map(\.id))
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78), value: sortedDrones.map(\.id))
        // Idle cluster repack: when the count changes (drone joins/leaves) the
        // slot offsets shift. Spring-animate on participant-id list so the repack
        // is a smooth spring rather than a positional snap.
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78), value: participants.map(\.id))
        // Mode switch speaker→idle (and vice-versa): slotOffset toggles between
        // arc and cluster layouts. Spring this transition so drones don't teleport
        // back to the swarm when the centre clears.
        .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.74), value: speaker == nil)
        // The swap itself, P1: arriving drone overshoots slightly into the
        // centre (presence); departing Pulsar eases out slower. Both keyed on
        // who holds the centre so they animate as a matched trade.
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.62), value: activeDroneCategory)
    }

    // NOTE: rendering of each participant now lives in `ParticipantSlotView`
    // (bottom of this file). That view is a SINGLE stable-identity element per
    // participant id whose position/scale glide between its orbit slot and the
    // centre as `isCentre` flips — so a character is NEVER torn down + rebuilt
    // (and hence never briefly duplicated) when it stops or starts speaking.
    // The old two-branch approach (FloatingPortraitView with an insert/remove
    // transition vs FloatingDronePortraitView) is what produced the "two Echoes"
    // ghost during a swap; it has been removed.

    /// The drone category that themes the CAPTION (tint + name pill). Keyed to
    /// the caption's speaker and survives the linger — so the bubble keeps its
    /// speaker colour + name even after the portrait has dropped back into the
    /// swarm (audio ended). nil = Pulsar (indigo) or no drone line.
    private var captionCategory: String? { viewModel.captionSpeakerCategory }

    /// The set of character keys the PARTICIPANT model already renders (in-flight
    /// drone categories, plus "pulsar" when Pulsar is a present participant). The
    /// queued-voices background layer must NOT re-render any of these, or the same
    /// character shows twice — once as its canonical drone/Pulsar orbit head and
    /// again as a redundant queued thumbnail behind the swarm (the "duplicates in
    /// the background" seen when a queued line's category is already an active
    /// drone). The participant orbit is the canonical representation.
    private var participantCharacterKeys: Set<String> {
        Set(participants.map { $0.category?.lowercased() ?? "pulsar" })
    }

    /// The queued voices eligible for a BACKGROUND thumbnail — the not-playing
    /// queue, with two dedupes applied so the background can never twin a
    /// character that's already on screen:
    ///   1. Drop any whose category is already a live participant (in-flight
    ///      drone, current speaker, or present Pulsar) — the participant orbit is
    ///      the canonical head for those.
    ///   2. Collapse remaining same-category queued items to ONE (a character is
    ///      a character, never a count), mirroring the participant model.
    /// Survives for the genuine no-overlap queue-preview case (a queued voice for
    /// a character with no in-flight drone of that type).
    private var dedupedQueuedItems: [QueueItem] {
        var shown = participantCharacterKeys
        var out: [QueueItem] = []
        for item in viewModel.queueItems where !item.isPlaying {
            let key = item.agent?.lowercased() ?? "pulsar"
            if shown.contains(key) { continue }
            shown.insert(key)
            out.append(item)
        }
        return Array(out.prefix(5))
    }

    /// Idle queued voices keep their existing orbiting thumbnails, behind the
    /// drones — but only the deduped set (see `dedupedQueuedItems`), so a queued
    /// line whose category is already a live participant never renders a second,
    /// "background" copy of that character behind the swarm.
    @ViewBuilder
    private var queuedThumbnails: some View {
        let queued = dedupedQueuedItems
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
    struct Participant: Identifiable {
        let id: String          // "pulsar" or the category name
        let category: String?   // nil = Pulsar
        let color: Color
        let isCentre: Bool
        let orbitIndex: Int     // valid only when !isCentre
    }

    /// The full participant list. Everyone is a PEER:
    ///   • CENTRE = whoever is currently SPEAKING (Pulsar or a drone). If no one
    ///     is speaking (between lines, or silent activity) there is NO centre —
    ///     all present participants orbit.
    ///   • ORBIT = every other PRESENT participant — the in-flight drones plus
    ///     Pulsar when he's present-but-silent. Pulsar is treated exactly like a
    ///     drone: he centres when he speaks, orbits when active-but-quiet.
    private var participants: [Participant] {
        var out: [Participant] = []
        let speakingCategory = activeDroneCategory          // nil = Pulsar (or no one)
        let pulsarSpeaking = speaker != nil && speakingCategory == nil

        // "Show active agents" toggle: when OFF, no drone heads render at all —
        // only Pulsar appears (a drone line then plays voice-only; see also
        // captionSource, which hides the drone bubble to match).
        let showAgents = viewModel.isShowActiveAgents

        // Centre = the active speaker, if anyone is speaking.
        if let speakingCategory {
            if showAgents {
                out.append(Participant(id: speakingCategory, category: speakingCategory,
                                       color: droneColor(for: speakingCategory),
                                       isCentre: true, orbitIndex: 0))
            }
            // else: a drone is speaking but agents are hidden → no head.
        } else if pulsarSpeaking {
            out.append(Participant(id: "pulsar", category: nil,
                                   color: droneColor(for: nil),
                                   isCentre: true, orbitIndex: 0))
        }
        // else: nobody speaking → no centre occupant; all participants orbit.

        // Orbit = every OTHER present participant — the in-flight drone types
        // (excluding the centred speaker) AND Pulsar himself when he's present
        // but NOT the centre speaker. Pulsar is a genuine PEER: when a drone
        // takes the centre (or Pulsar has just finished while drones are still
        // in-flight), Pulsar occupies an orbit slot and GLIDES centre→orbit as
        // the SAME single view (see ParticipantSlotView) — he does NOT vanish.
        // He only leaves the swarm when the whole panel goes idle/hidden, which
        // `panelShouldBeVisible` / the linger logic decides — untouched here.
        var orbitKeys: [(id: String, category: String?)] = []

        // Pulsar orbits whenever he's present (main session active — drones
        // in-flight or audio playing) but isn't the one holding the centre.
        // Gate on `showAgents` too: with agents hidden the swarm is suppressed,
        // so the peer-orbit Pulsar thumbnail is suppressed with it (only a
        // speaking Pulsar shows a head then, via the centre branch above).
        let pulsarOrbits = showAgents && viewModel.pulsarIsPresent && !pulsarSpeaking
        if pulsarOrbits {
            orbitKeys.append((id: "pulsar", category: nil))
        }

        let present = showAgents ? inFlightCategories : []
        for category in DroneRegistry.categories
        where category != speakingCategory && present.contains(category) {
            orbitKeys.append((id: category, category: category))
        }
        for (i, k) in orbitKeys.enumerated() {
            out.append(Participant(id: k.id, category: k.category,
                                   color: droneColor(for: k.category),
                                   isCentre: false, orbitIndex: i))
        }
        return out
    }

    /// How many orbit slots are currently rendered — drives the arc spacing.
    private var orbitSlotCount: Int {
        participants.filter { !$0.isCentre }.count
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
                                   activeColor: droneColor(for: captionCategory))   // caption tint survives linger
                    .id(caption)
                    .offset(x: layout.captionXOffset)
                    // Use 2× glowMargin horizontally so the plusLighter rim-glow
                    // (blur radius up to ~6pt, margin = 16pt) has a full margin
                    // before the panel edge and doesn't hard-clip on either side.
                    .padding(.horizontal, captionEdgePadding * 2)
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

    private var captionSource: String? {
        // When the swarm is hidden, a drone line shows no head — so it shows no
        // bubble either (voice-only). Pulsar's own captions are unaffected.
        if !viewModel.isShowActiveAgents, isDrone(viewModel.playback.currentAgentCategory) {
            return nil
        }
        return viewModel.playback.currentText
    }

    /// A stable identity for the caption's speaker — the drone category, else
    /// "pulsar", else nil when there's no line. Used to detect a genuine speaker
    /// CHANGE so a caption is never lingered under a DIFFERENT speaker. Keyed to
    /// the CAPTION signal (which persists through the linger), NOT to
    /// `activeSpeaker` (which now goes nil the instant audio ends) — otherwise
    /// audio-end would look like a speaker change and kill the linger.
    private var currentSpeakerKey: String? {
        // No current line at all → no owner.
        guard viewModel.playback.currentText?.isEmpty == false else { return nil }
        return captionCategory ?? "pulsar"
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

    /// Place slot `index` of `total` as a COMPACT CLUSTER centred on the hub
    /// angle (straight up): slots fan symmetrically around the centre with a
    /// tight fixed step, so a few drones sit as a snug pod rather than spread
    /// across a wide rail. One slot sits dead-centre; the swarm drift does the
    /// rest of the mingling.
    private func orbitAngle(index: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        // Symmetric offset from centre: e.g. total=3 → offsets -1,0,+1;
        // total=4 → -1.5,-0.5,+0.5,+1.5.
        let offset = Double(index) - Double(total - 1) / 2.0
        let degrees = clusterCenterDegrees + offset * clusterStepDegrees
        return degrees * .pi / 180
    }

    /// The base slot offset for orbit participant `index` of `total`. Two modes:
    ///   • A speaker holds the centre → the ARC orbit above the hub (arriving /
    ///     departing speakers still pass along it).
    ///   • Idle (no speaker) → a SYMMETRIC CLUSTER: the whole swarm squeezes into
    ///     a vertically + horizontally balanced pod centred in the head zone.
    private func slotOffset(index: Int, total: Int) -> CGSize {
        if speaker != nil {
            let angle = orbitAngle(index: index, total: total)
            return CGSize(width: cos(angle) * orbitRadius,
                          height: sin(angle) * orbitRadius + orbitYOffset)
        }
        let offs = symmetricClusterOffsets(total)
        return index < offs.count ? offs[index] : .zero
    }

    /// Symmetric-cluster slot offsets for the idle swarm, centred on the head
    /// zone. Balanced rows (a horizontal AND a vertical mirror) that adapt to the
    /// live count 1…7. Rows are chosen so the MIDDLE is the WIDEST and the top /
    /// bottom taper in — an OVAL/hexagonal blob, not an hourglass "H":
    ///   1:[1]  2:[2]  3:[3]  4:[2,2]  5:[1,3,1]  6:[3,3]  7:[2,3,2]
    /// Row counts are a palindrome so the pod mirrors top-to-bottom; each row is
    /// horizontally centred. Slot order follows participant order, so a change in
    /// the live set re-packs the pod symmetrically.
    private func symmetricClusterOffsets(_ total: Int) -> [CGSize] {
        let rows: [Int]
        switch max(total, 0) {
        case 0: return []
        case 1: rows = [1]
        case 2: rows = [2]
        case 3: rows = [3]
        case 4: rows = [2, 2]
        case 5: rows = [1, 3, 1]      // plus/diamond — wide middle, not a pinched X
        case 6: rows = [3, 3]
        default: rows = [2, 3, 2]     // hexagon+centre oval (7 = the ceiling)
        }
        var offsets: [CGSize] = []
        let rowCount = rows.count
        for (r, count) in rows.enumerated() {
            let y = (CGFloat(r) - CGFloat(rowCount - 1) / 2) * clusterSpacing + orbitYOffset
            for c in 0..<count {
                let x = (CGFloat(c) - CGFloat(count - 1) / 2) * clusterSpacing
                offsets.append(CGSize(width: x, height: y))
            }
        }
        return offsets
    }
}

// MARK: - Participant slot (single stable-identity view: glides centre ↔ orbit)

/// ONE on-screen element per participant id. It is NEVER two mutually-exclusive
/// branches — instead it layers BOTH representations (the full-size speaker
/// portrait and the small orbit thumbnail) in a single view and cross-fades
/// between them by opacity, while the whole element ANIMATES its offset + scale
/// between the centre and its orbit slot as `isCentre` flips.
///
/// Because the view's identity (`.id(p.id)`) is stable across the centre↔orbit
/// transition, SwiftUI does NOT tear the centre view down and insert a new
/// thumbnail (the old bug — that overlap rendered the SAME character twice, the
/// "multiple Echo"). The same element glides: an outgoing speaker travels
/// centre→its orbit slot while the incoming one travels its slot→centre, and
/// they pass cleanly — the real "matched arc".
///
/// - Centre: full portrait + glow + live lip-sync (amplitude from the speaker),
///   scale 1, offset .zero.
/// - Orbit: the drone thumbnail with its signature drift, scaled to the
///   thumbnail size, offset to its orbit slot.
private struct ParticipantSlotView: View {
    let participant: FloatingHeadsView.Participant
    /// The active speaker snapshot — drives the CENTRE occupant's live amplitude
    /// (lip-sync) and voice label. Only meaningful while `participant.isCentre`.
    let speaker: DashboardViewModel.SpeakerSnapshot?
    /// This participant's orbit-slot offset (arc while a speaker holds the
    /// centre, cluster when idle) — where the thumbnail sits when NOT centre,
    /// and where the element rests/departs to.
    let orbitOffset: CGSize
    let thumbnailSize: CGFloat
    let reduceMotion: Bool
    let portraitManager: PortraitManager

    /// Full centre portrait size (matches FloatingPortraitView.portraitSize).
    private let centrePortraitSize: CGFloat = 120

    private var isCentre: Bool { participant.isCentre }
    private var category: String { participant.category ?? "pulsar" }

    /// The scale the ORBIT representation must be drawn at so, together with the
    /// centre-scale animation, the thumbnail reads at `thumbnailSize`. The centre
    /// portrait is 120pt; when orbiting we scale the whole element down to the
    /// thumbnail's fraction of that.
    private var orbitScale: CGFloat { thumbnailSize / centrePortraitSize }

    var body: some View {
        ZStack {
            // CENTRE representation — full portrait + glow + lip-sync. Faded in
            // only while this participant holds the centre. Rendered at native
            // 120pt; the element scale stays 1 when centre.
            // [FIX 1 — perf] Only run the expensive 60Hz FloatingPortraitView
            // (aura/glow/bob TimelineView) for the centre participant. Orbiting
            // participants are opacity-0 here anyway, so there is no visual change
            // — but previously 7 slots × 60Hz ran simultaneously. Now only the
            // active centre fires; the orbit uses the cheap thumbnail below.
            // [FIX 2 — voiceLabel] Use the participant's OWN identity for the
            // fallback initial rather than the active speaker's label. Without
            // this, all orbit heads show the speaker's initial on portrait
            // fallback, which is wrong even at opacity-0 (it leaks through the
            // crossfade).
            if isCentre {
                FloatingPortraitView(
                    voiceName: speaker?.voiceLabel ?? (participant.category?.capitalized ?? "Pulsar"),
                    amplitude: speaker?.amplitude ?? 0,
                    voiceColor: participant.color,
                    portraitManager: portraitManager,
                    droneName: category,
                    glowColor: participant.color
                )
                .allowsHitTesting(true)
                // Explicit opacity transition so the portrait fades in/out cleanly
                // as a participant enters/leaves the centre, matching the thumbnail
                // fade on the orbit layer below.
                .transition(.opacity)
            }

            // ORBIT representation — the drone thumbnail with signature drift.
            // Faded in only while this participant is orbiting. Its own
            // slotOffset is ZEROed here because the CONTAINER carries the offset
            // (so the SAME element glides); the drift still animates locally.
            FloatingDronePortraitView(
                category: category,
                isActiveSpeaker: false,
                liveAmplitude: 0,
                thumbnailSize: centrePortraitSize,   // drawn full then element-scaled
                slotOffset: .zero,
                index: participant.orbitIndex,
                reduceMotion: reduceMotion,
                portraitManager: portraitManager
            )
            .opacity(isCentre ? 0 : 1)
            .allowsHitTesting(!isCentre)
        }
        // Element scale: full at centre, thumbnail-fraction when orbiting. The
        // crossfade above swaps the visible treatment; this scale + the offset
        // below carry the single element between the two footprints.
        .scaleEffect(isCentre ? 1 : orbitScale)
        // Element position: dead-centre when speaking, the orbit slot otherwise.
        // Animated by the ZStack-level springs in `headZone` (keyed on the
        // speaker / activeDroneCategory / participant-list), so the glide is a
        // spring, not a snap.
        .offset(isCentre ? .zero : orbitOffset)
        // A participant genuinely JOINING or LEAVING the swarm (a sub-agent
        // starts / finishes) still animates in/out — but this is entry/exit of
        // the whole element, NOT the centre↔orbit swap, so it can never produce
        // a duplicate of an existing character.
        .transition(.asymmetric(
            insertion: .scale(scale: 0.1).combined(with: .opacity).combined(with: .offset(y: 30)),
            removal: .scale(scale: 0.6).combined(with: .opacity).combined(with: .offset(y: -24))
        ))
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
                portraitManager: portraitManager,
                // Render the pending line's own drone face (nil agent = Pulsar).
                droneName: item.agent ?? "pulsar"
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
