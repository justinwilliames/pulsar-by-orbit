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
    /// The session's in-flight sub-agent drones, as running mission rows.
    let drones: [MissionTask]

    /// The board title: sticky name if present, else the cwd label, else a short
    /// id tag.
    var displayTitle: String {
        if !name.isEmpty { return name }
        if !label.isEmpty { return label }
        return "#" + String(id.prefix(4))
    }
}
