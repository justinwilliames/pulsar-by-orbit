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

    /// One drone's fixed identity: its category id, a human-readable role, its
    /// locked brand colour, and the macOS `say -v` voice it speaks in. The voice
    /// is chosen by the character's persona + assumed gender, from the humanoid
    /// voices actually installed on this machine (verified via
    /// AVSpeechSynthesisVoice gender) — never a robotic/novelty voice.
    struct Drone: Sendable {
        let category: String
        let role: String
        let color: Color
        let voice: String
    }

    /// The default macOS voice for Pulsar (and any untagged / unknown line):
    /// Daniel, the male UK orchestrator voice.
    static let pulsarVoice = "Daniel"

    /// The LOCKED taxonomy + colours, plus a unique humanoid voice per character.
    /// Order is the canonical category list.
    ///
    /// Voice choices — persona + assumed gender → a distinct, genuinely humanoid
    /// ENGLISH voice installed on this machine. This box has only three humanoid
    /// English MALE voices (Daniel, Rishi, Aman), one of which is Pulsar's, so the
    /// two rugged males (Voyager, Atlas) take Aman + Rishi and the gender-neutral
    /// communicator Echo takes a female voice (Tessa) — every character speaks in a
    /// real English voice rather than a non-English one mispronouncing English.
    /// To upgrade any of them: download a premium voice (System Settings → Spoken
    /// Content → System Voice → Manage Voices) and edit the `voice:` string here.
    ///   • voyager  (M, rugged explorer)      → Aman     (en-IN) — energetic, adventurous
    ///   • sentinel (F, precise reviewer)     → Karen    (en-AU) — crisp, authoritative
    ///   • nova     (F, eager builder)        → Samantha (en-US) — bright, upbeat
    ///   • nebula   (F, artist)               → Moira    (en-IE) — warm, lyrical
    ///   • echo     (F, writer/communicator)  → Tessa    (en-ZA) — clear, articulate
    ///   • atlas    (M, sturdy generalist)    → Rishi    (en-IN) — deep, steady
    static let drones: [Drone] = [
        Drone(category: "voyager",  role: "explorer",   color: Color(red: 0.95, green: 0.66, blue: 0.23), voice: "Aman"),     // amber
        Drone(category: "sentinel", role: "reviewer",   color: Color(red: 0.35, green: 0.78, blue: 0.88), voice: "Karen"),    // cyan
        Drone(category: "nova",     role: "builder",    color: Color(red: 0.36, green: 0.82, blue: 0.42), voice: "Samantha"), // green
        Drone(category: "nebula",   role: "artist",     color: Color(red: 0.91, green: 0.36, blue: 0.82), voice: "Moira"),    // magenta
        Drone(category: "echo",     role: "writer",     color: Color(red: 0.25, green: 0.82, blue: 0.78), voice: "Tessa"),    // teal
        Drone(category: "atlas",    role: "generalist", color: Color(red: 0.53, green: 0.58, blue: 0.66), voice: "Rishi"),    // slate
    ]

    /// The canonical category list (drone names only — Pulsar is not a drone).
    static let categories: [String] = drones.map(\.category)

    private static let byCategory: [String: Drone] =
        Dictionary(uniqueKeysWithValues: drones.map { ($0.category, $0) })

    /// The macOS `say -v` voice for a line tagged with `category`. Returns the
    /// drone's voice for a known drone; otherwise Pulsar's Daniel for
    /// "pulsar", nil, or any unknown/unrecognised category.
    static func voice(for category: String?) -> String {
        guard let category, let drone = byCategory[category.lowercased()] else {
            return pulsarVoice
        }
        return drone.voice
    }

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

/// The macOS `say -v` voice for a category (drone voice, else Pulsar's Daniel).
func droneVoice(for category: String?) -> String {
    DroneRegistry.voice(for: category)
}
