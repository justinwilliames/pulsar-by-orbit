import SwiftUI

/// One row on the Task Mode "Missions" board — a unit of live Claude Code work
/// (a sub-agent drone, or the main session) with a glanceable status.
struct MissionTask: Identifiable, Equatable {
    enum Status: Equatable {
        case running        // actively working
        case waiting        // needs the human — blocked on input/approval
        case done           // finished
        case blocked        // errored / stuck

        var label: String {
            switch self {
            case .running: "Running"
            case .waiting: "Needs you"
            case .done:    "Done"
            case .blocked: "Blocked"
            }
        }
        var systemImage: String {
            switch self {
            case .running: "circle.dotted"
            case .waiting: "hand.raised.fill"
            case .done:    "checkmark.circle.fill"
            case .blocked: "exclamationmark.triangle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .running: .green
            case .waiting: .orange
            case .done:    .secondary
            case .blocked: .red
            }
        }
        /// Board sort priority — needs-you floats to the top.
        var priority: Int {
            switch self {
            case .waiting: 0
            case .blocked: 1
            case .running: 2
            case .done:    3
            }
        }
    }

    let id: String
    let title: String
    /// Drone category for colour theming; nil = Pulsar / main session (indigo).
    let category: String?
    let status: Status
    /// Short subtitle (elapsed, last line, or state note).
    let detail: String
}
