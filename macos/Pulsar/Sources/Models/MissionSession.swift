import SwiftUI

/// One Claude Code SESSION on the Missions board — the orchestrator parent
/// (Pulsar) plus its nested sub-agent drones. The board groups live work by
/// session: each session is one row with its drones beneath it.
struct MissionSession: Identifiable, Equatable {
    enum Phase: String {
        case working
        case waiting

        /// "Working" while the turn runs; "Paused" once the turn ends. The Stop
        /// hook fires on turn-END, not on proven blocked-on-input — so "Paused"
        /// is the honest word, and protects the board's trust premise. (Upgrade
        /// to "Needs you" only when a hook can prove true blocked-input.)
        var label: String { self == .waiting ? "Paused" : "Working" }
        var tint: Color { self == .waiting ? .orange : .green }
        var systemImage: String { self == .waiting ? "hand.raised.fill" : "circle.dotted" }
    }

    /// Session id.
    let id: String
    /// Sticky session name — the session's first user message. May be empty (the
    /// title falls back to `label`, then a short id tag).
    let name: String
    /// Human-readable label (cwd basename, else a short id tag).
    let label: String
    let phase: Phase
    let lastSeen: Date
    /// The session's current git branch (empty when non-git / unknown).
    let branch: String
    /// The git repo name (empty when non-git / unknown).
    let repo: String
    /// Short snippet of the last assistant action (empty when unknown).
    let lastAction: String
    /// True when the user manually renamed this session — the definitive title.
    let userNamed: Bool
    /// The session's in-flight sub-agent drones, as running mission rows.
    let drones: [MissionTask]

    init(id: String, name: String, label: String, phase: Phase, lastSeen: Date,
         branch: String = "", repo: String = "", lastAction: String = "",
         userNamed: Bool = false, drones: [MissionTask]) {
        self.id = id
        self.name = name
        self.label = label
        self.phase = phase
        self.lastSeen = lastSeen
        self.branch = branch
        self.repo = repo
        self.lastAction = lastAction
        self.userNamed = userNamed
        self.drones = drones
    }

    /// Branches too generic to serve as a title on their own — a "main" row tells
    /// you nothing, so it never gets promoted above the first-message name.
    private static let genericBranches: Set<String> = ["main", "master", "trunk", "develop", "dev", "head"]

    /// The board title. Precedence, highest → lowest:
    ///   1. a user rename (definitive);
    ///   2. the sticky/first-message name (or LLM title, which replaced the seed);
    ///   3. a NON-generic branch (names the line of work when there's no name);
    ///   4. the cwd label;
    ///   5. a short id tag.
    /// Branch outranks the label but NOT a real name — a good first message beats
    /// "feat/x", while a bare repo label loses to it.
    var displayTitle: String {
        if userNamed, !name.isEmpty { return name }
        if !name.isEmpty { return name }
        let b = branch.trimmingCharacters(in: .whitespaces)
        if !b.isEmpty, !Self.genericBranches.contains(b.lowercased()) { return b }
        if !label.isEmpty { return label }
        return "#" + String(id.prefix(4))
    }

    /// The one-line context strip under the title — the at-a-glance discriminator
    /// that separates N same-repo sessions: "branch · last-action · relative-time",
    /// dropping any empty segment. When no branch, the repo/label fills that slot
    /// so the line is never blank. `lastAction` is truncated so it can't shove the
    /// time off the 360pt row.
    var contextLine: String {
        var parts: [String] = []
        // Lead with the line-of-work: branch if we have one, else the project.
        let b = branch.trimmingCharacters(in: .whitespaces)
        if !b.isEmpty {
            parts.append(b)
        } else {
            let proj = repo.isEmpty ? label : repo
            if !proj.isEmpty { parts.append(proj) }
        }
        let action = lastAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !action.isEmpty { parts.append(String(action.prefix(40))) }
        parts.append(Self.relativeTime(lastSeen))
        return parts.joined(separator: " · ")
    }

    /// Compact relative time ("now", "2m", "3h", "5d") for the context strip.
    static func relativeTime(_ date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 45 { return "now" }
        let mins = secs / 60
        if mins < 60 { return "\(max(1, mins))m" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    // MARK: - Identity signature (deterministic, hashed from session_id)

    /// A pre-vetted, well-spaced palette drawn from the drone hues, so the parent
    /// identity chips read as ONE calm family with the nested drone rows — no new
    /// colour vocabulary. Ordered for maximum adjacent contrast.
    private static let signaturePalette: [Color] = [
        Color(red: 0.42, green: 0.72, blue: 0.92),  // azure  (sentinel)
        Color(red: 0.95, green: 0.66, blue: 0.23),  // amber  (voyager)
        Color(red: 0.36, green: 0.82, blue: 0.42),  // green  (nova)
        Color(red: 0.91, green: 0.36, blue: 0.82),  // magenta(nebula)
        Color(red: 0.18, green: 0.75, blue: 0.72),  // teal   (echo)
        Color(red: 0.50, green: 0.25, blue: 0.75),  // grape  (atlas)
        Color(red: 0x81 / 255, green: 0x8C / 255, blue: 0xF8 / 255),  // indigo (pulsar/orbitLight)
    ]

    /// A stable, non-negative hash of the session id — FNV-1a, so the same id
    /// always maps to the same chip regardless of process (Swift's Hasher is
    /// per-run seeded and would give a different colour every launch). Delegates
    /// to `SessionIdentity` so the view and the tested backstop share one hash.
    private var stableHash: UInt64 { SessionIdentity.stableHash(id) }

    /// The session's deterministic identity colour — same id, same colour, every
    /// run. A fast pre-attentive AID, not the uniqueness guarantee: the 7-hue
    /// hash collides ~1/7 per pair (guaranteed past 7 same-repo sessions), so
    /// `shortTag` + `monogram` carry the actual distinctness. Kept as-is.
    var identityColor: Color {
        Self.signaturePalette[Int(stableHash % UInt64(Self.signaturePalette.count))]
    }

    /// The always-distinct backstop: "#" + the first 4 id chars (e.g. "#a7f3").
    /// Stable per session and unique in practice, so even when colour + branch +
    /// last-action all match, the human can still tell two rows apart and refer to
    /// one ("the #a7f3 one").
    var shortTag: String { SessionIdentity.shortTag(id: id) }

    /// A 1–2 char monogram carrying identity as TEXT (so the chip never relies on
    /// colour alone — colour-blind-safe, and distinct even on a hash collision).
    /// NEVER branch-derived (branch initials collapse for same-repo sessions):
    /// a user rename → the person's initials; otherwise two id-hashed chars, so
    /// two same-repo sessions get DIFFERENT monograms. `name` holds the user's
    /// chosen title exactly when `userNamed` is set.
    var monogram: String {
        SessionIdentity.monogram(id: id, userNamed: userNamed, userName: name)
    }
}
