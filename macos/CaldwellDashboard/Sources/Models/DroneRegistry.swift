import SwiftUI

/// The sub-agent "drone" taxonomy.
///
/// When the main Claude Code session spawns sub-agents, each in-flight one is
/// rendered as a colour-coded sibling robot orbiting Pulsar. A narration line
/// tagged with a drone *category* makes that drone the active speaker — its
/// colour themes the subtitle rim-glow + portrait glow, and its frame set
/// (`<category>-mouth-0…4` + `<category>-blink`) drives the lip-sync.
///
/// The frame prefix is ALWAYS the category name. The default speaker is Pulsar
/// (indigo `.orbitLight`), used for "pulsar", nil, or any unknown category.
enum DroneRegistry {

    /// One drone's fixed identity: its category id, a human-readable role, and
    /// its locked brand colour.
    struct Drone: Sendable {
        let category: String
        let role: String
        let color: Color
    }

    /// The LOCKED taxonomy + colours. Order is the canonical category list.
    static let drones: [Drone] = [
        Drone(category: "voyager",  role: "explorer",   color: Color(red: 0.95, green: 0.66, blue: 0.23)), // amber
        Drone(category: "sentinel", role: "reviewer",   color: Color(red: 0.35, green: 0.78, blue: 0.88)), // cyan
        Drone(category: "nova",     role: "builder",    color: Color(red: 0.36, green: 0.82, blue: 0.42)), // green
        Drone(category: "nebula",   role: "artist",     color: Color(red: 0.91, green: 0.36, blue: 0.82)), // magenta
        Drone(category: "echo",     role: "writer",     color: Color(red: 0.25, green: 0.82, blue: 0.78)), // teal
        Drone(category: "atlas",    role: "generalist", color: Color(red: 0.53, green: 0.58, blue: 0.66)), // slate
    ]

    /// The canonical category list (drone names only — Pulsar is not a drone).
    static let categories: [String] = drones.map(\.category)

    private static let byCategory: [String: Drone] =
        Dictionary(uniqueKeysWithValues: drones.map { ($0.category, $0) })

    /// The colour for a given category. Returns the drone's locked colour for a
    /// known drone; otherwise the default Pulsar indigo (`.orbitLight`) for
    /// "pulsar", nil, or any unknown/unrecognised category.
    static func droneColor(for category: String?) -> Color {
        guard let category, let drone = byCategory[category.lowercased()] else {
            return .orbitLight
        }
        return drone.color
    }

    /// Whether `category` names an actual drone (not Pulsar / nil / unknown).
    static func isDrone(_ category: String?) -> Bool {
        guard let category else { return false }
        return byCategory[category.lowercased()] != nil
    }
}

/// Free-function conveniences matching the spec's call sites.
func droneColor(for category: String?) -> Color {
    DroneRegistry.droneColor(for: category)
}

func isDrone(_ category: String?) -> Bool {
    DroneRegistry.isDrone(category)
}
