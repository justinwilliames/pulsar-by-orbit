import SwiftUI
import AppKit

/// The Task Mode "Missions" board — live Claude Code work grouped BY SESSION.
/// Each session is a Pulsar orchestrator parent row with its sub-agent drones
/// nested beneath. Shows sessions the user messaged in the last 7 days (plus any
/// with live drones); each has a dismiss (x) to hide it. A "Needs you" session
/// (its turn ended, waiting on the user) is tinted so it's impossible to miss.
struct MissionsView: View {
    let viewModel: DashboardViewModel

    private var sessions: [MissionSession] {
        viewModel.missionSessions.sorted {
            // Needs-you floats to the top; then most-recent first.
            if ($0.phase == .waiting) != ($1.phase == .waiting) {
                return $0.phase == .waiting
            }
            return $0.lastSeen > $1.lastSeen
        }
    }

    /// "N sessions · M paused" summary from live counts, with the paused
    /// segment rendered in the waiting-phase ORANGE so it actually reads (plain
    /// .secondary made it invisible). Composed as a single Text so the two tints
    /// sit on one line.
    private var summaryLine: Text {
        let count = sessions.count
        let paused = sessions.filter { $0.phase == .waiting }.count
        var line = Text("\(count) session\(count == 1 ? "" : "s")")
            .foregroundColor(.secondary)
        if paused > 0 {
            line = line
                + Text(" · ").foregroundColor(.secondary)
                + Text("\(paused) paused").foregroundColor(.orange)
        }
        return line
    }

    var body: some View {
        if sessions.isEmpty {
            emptyState
                .task { await viewModel.loadSessions() }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    header
                    ForEach(sessions) { session in
                        sessionGroup(session)
                    }
                }
                .padding(16)
            }
            .task { await viewModel.loadSessions() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("MISSIONS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            summaryLine
                .font(.caption.weight(.semibold))
                .tracking(0.5)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Session group (parent + nested drones)

    private func sessionGroup(_ session: MissionSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionParentRow(session: session, viewModel: viewModel)
            if !session.drones.isEmpty {
                nestedDrones(session)
            }
        }
    }

    // MARK: - Nested drones

    private func nestedDrones(_ session: MissionSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Left rail — a thin indigo spine tying the drones to their parent,
            // topped with a small cap so it reads as a tree BRANCH rather than a
            // free-floating bar. Centred under the parent mark: the parentRow has
            // 8pt padding + a 24pt PulsarMark, so the mark's centre sits ~20pt
            // from the group's leading edge; a 2pt rail centres there at 19pt
            // leading. Colour raised to orbitLight.opacity(0.5) so it's visible
            // on the dark popover (the old 0.3 washed out).
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.orbitLight.opacity(0.5))
                    .frame(width: 6, height: 6)
                Rectangle()
                    .fill(Color.orbitLight.opacity(0.5))
                    .frame(width: 2)
            }
            .padding(.leading, 19)   // centres the 2pt rail under the parent mark

            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.drones) { drone in
                    droneRow(drone)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// One nested drone row — the drone's static portrait + its NAME + a
    /// "Role · detail" secondary line + a status pill. Restores per-drone
    /// personality WITHOUT gaudiness: the pill and a thin leading accent both
    /// carry the drone's OWN hue, and a running portrait breathes gently so live
    /// work reads as alive. Calm on purpose — this is a menu-bar list.
    private func droneRow(_ task: MissionTask) -> some View {
        let category = task.category
        let name = (category ?? "pulsar").capitalized
        let role = DroneRegistry.role(for: category).capitalized
        let hue = droneColor(for: category)
        // The pill uses the drone's own hue while running so the cast is
        // distinguishable at a glance; terminal states keep their semantic
        // colour (done=secondary, blocked=red, paused=orange).
        let pillTint = task.status == .running ? hue : task.status.tint

        return HStack(spacing: 10) {
            dronePortrait(category, running: task.status == .running)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.semibold))
                Text(role.isEmpty ? task.detail : "\(role) · \(task.detail)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Label(task.status.label, systemImage: task.status.systemImage)
                .font(.caption2)
                .foregroundStyle(pillTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(pillTint.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .background(alignment: .leading) {
            // A thin left-edge accent in the drone's hue — a subtle presence
            // that lets the crew read as distinct characters, not identical rows.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(hue.opacity(0.55))
                .frame(width: 3)
        }
    }

    /// Small static drone portrait (mouth-0 frame), colour-bordered by drone hue.
    /// Falls back to the Pulsar frame for unknown/nil categories. A `running`
    /// portrait breathes — a gentle scale+opacity oscillation — so live work
    /// feels alive without turning the list into a toy.
    private func dronePortrait(_ category: String?, running: Bool) -> some View {
        let key = category ?? "pulsar"
        let image = NSImage(named: "\(key)-mouth-0")
            ?? NSImage(named: "pulsar-mouth-0")
            ?? NSImage()
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(droneColor(for: category), lineWidth: 1.5)
            )
            .modifier(BreathingModifier(active: running))
    }

    /// A calm "breathing" pulse for a running drone portrait — a small
    /// scale + opacity oscillation that reads as living work, not a toy. Inert
    /// (identity) when `active` is false, so paused/done/blocked drones sit still.
    private struct BreathingModifier: ViewModifier {
        let active: Bool
        @State private var breathe = false

        func body(content: Content) -> some View {
            content
                .scaleEffect(active && breathe ? 1.06 : 1.0)
                .opacity(active && breathe ? 0.82 : 1.0)
                .animation(
                    active
                        ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                        : .default,
                    value: breathe)
                .onAppear { if active { breathe = true } }
                .onChange(of: active) { _, isActive in breathe = isActive }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(Color.orbit)
            Text("No active missions")
                .font(.caption.weight(.medium))
            Text("When Claude Code sessions run, they'll appear here grouped by session.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Session parent row (identity chip + title + context strip + rename)

/// The orchestrator parent row for one session. Its OWN struct so it can hold the
/// inline-rename `@State` per row. The identity chip (deterministic colour +
/// monogram) is the pre-attentive distinguisher — N same-repo sessions become N
/// different chips; the context strip (branch · last-action · time) names each.
private struct SessionParentRow: View {
    let session: MissionSession
    let viewModel: DashboardViewModel

    @State private var isEditing = false
    @State private var editingTitle = ""
    @State private var isHovering = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // The jump target is ONLY the leading content (chip + title/context) —
            // a plain Button that excludes the trailing pill + dismiss (x), so those
            // controls keep their own hit areas and never fire a jump. Disabled
            // while renaming so a click in the TextField edits rather than warps.
            Button(action: openSession) {
                HStack(spacing: 10) {
                    // The chip is the parent's RESTING identity; when drones run, the
                    // nested rows below carry the live portraits. Keeping the chip here
                    // (not a drone portrait) means the parent stays identifiable even
                    // mid-swarm.
                    IdentityChip(color: session.identityColor, monogram: session.monogram, size: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        titleLine
                        secondaryStrip
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isEditing)   // renaming: clicks edit the field, don't jump
            .help("Open this session in Claude")

            Spacer(minLength: 8)

            statusPill(session.phase)

            Button {
                Task { await viewModel.dismissSession(session.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss this session")
        }
        .padding(8)
        .background(
            (session.phase == .waiting ? Color.orange.opacity(0.10) : Color.orbit.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            // A faint highlight on hover so the (clickable) row reads as live —
            // calm, no border, suppressed while renaming to avoid competing chrome.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isHovering && !isEditing ? 0.05 : 0))
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename") { beginEditing() }
            Button("Dismiss") { Task { await viewModel.dismissSession(session.id) } }
        }
    }

    /// Title line — swaps between a static Text (with a hover-reveal pencil) and
    /// an inline TextField while renaming. The field is width-capped so it can
    /// never shove the pill/dismiss off the 360pt row.
    @ViewBuilder
    private var titleLine: some View {
        if isEditing {
            TextField("Name this session", text: $editingTitle)
                .textFieldStyle(.plain)
                .font(.caption.weight(.semibold))
                .focused($titleFocused)
                .frame(maxWidth: 190, alignment: .leading)
                .onSubmit { commitEditing() }
                .onExitCommand { isEditing = false }   // Esc cancels
                .onChange(of: titleFocused) { _, focused in
                    // Losing focus (click away) commits, matching a rename field's
                    // usual behaviour — no orphaned half-edits.
                    if !focused && isEditing { commitEditing() }
                }
        } else {
            HStack(spacing: 4) {
                Text(session.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isHovering {
                    Button(action: beginEditing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rename this session")
                    // A calm jump affordance so the row reads as clickable — a
                    // small "open" glyph revealed on hover, tertiary, no button
                    // chrome. The actual click is handled by the wrapping Button.
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Under-title context strip: the context line (or orchestration summary while
    /// drones run) PLUS the always-present `shortTag` as a subtle, monospaced
    /// trailing tag. The tag is the collision backstop the human can point at — so
    /// even if colour + branch + last-action all match, the two rows still read
    /// apart ("the #a7f3 one"). The context line truncates first (lower layout
    /// priority) so the tag is never the thing that gets clipped off the 360pt row.
    private var secondaryStrip: some View {
        HStack(spacing: 5) {
            Text(secondaryLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            Text(session.shortTag)
                .font(.caption2.monospaced())
                .foregroundStyle(.quaternary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    /// Under-title context text. With drones running, keep the orchestration
    /// summary; otherwise show the session's signature line — the actual
    /// at-a-glance discriminator that separates same-repo rows.
    private var secondaryLine: String {
        let count = session.drones.count
        if count > 0 {
            return "orchestrating \(count) agent\(count == 1 ? "" : "s")"
        }
        return session.contextLine
    }

    /// Deep-link into Claude Desktop and navigate to this exact session (no fork).
    /// Confirmed live: `claude://resume?session=<session_id>`. Guarded so a
    /// malformed id can never force-unwrap a nil URL.
    private func openSession() {
        guard !isEditing,
              let url = URL(string: "claude://resume?session=\(session.id)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func beginEditing() {
        editingTitle = session.displayTitle
        isEditing = true
        titleFocused = true
    }

    private func commitEditing() {
        let name = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !name.isEmpty, name != session.displayTitle else { return }
        Task { await viewModel.renameSession(session.id, to: name) }
    }

    private func statusPill(_ phase: MissionSession.Phase) -> some View {
        Label(phase.label, systemImage: phase.systemImage)
            .font(.caption2)
            .foregroundStyle(phase.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(phase.tint.opacity(0.15), in: Capsule())
    }
}

// MARK: - Identity chip

/// A deterministic colour+monogram chip — the pre-attentive session distinguisher
/// on the Missions board. Colour is hashed from the session id (an accelerant);
/// the monogram carries identity as TEXT so it survives colour-blindness and any
/// hash collision. Palette is sourced from the drone hues so chips and nested
/// drone rows read as one calm family.
private struct IdentityChip: View {
    let color: Color
    let monogram: String
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.265, style: .continuous)
            .fill(color.opacity(0.9))
            .frame(width: size, height: size)
            .overlay(
                Text(monogram)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            )
    }
}
