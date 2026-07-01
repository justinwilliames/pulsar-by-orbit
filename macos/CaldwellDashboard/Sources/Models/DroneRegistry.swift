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

    /// A per-drone signature motion so each character moves distinctly rather
    /// than every drone sharing one bob (which read as mere recolours):
    ///   • bobAmplitude — px of orbital bob (wider = more restless)
    ///   • bobFrequency — bob speed multiplier (higher = busier)
    ///   • activeScale  — pop size when this drone takes the centre
    struct MotionTrait: Sendable {
        let bobAmplitude: CGFloat
        let bobFrequency: Double
        let activeScale: CGFloat
    }

    /// One drone's fixed identity: its category id, a human-readable role, its
    /// locked brand colour, the macOS `say -v` voice it speaks in, a short
    /// non-colour role badge (so the drones are distinguishable without relying
    /// on hue alone), and its signature motion trait. Voice is chosen by the
    /// character's persona + assumed gender, from the humanoid voices actually
    /// installed on this machine — never a robotic/novelty voice.
    struct Drone: Sendable {
        let category: String
        let role: String
        let color: Color
        let voice: String
        /// Single-character role badge shown in the portrait corner (E=explorer,
        /// R=reviewer, B=builder, A=artist, W=writer, G=generalist).
        let badge: String
        let motion: MotionTrait
    }

    /// The default macOS voice for Pulsar (and any untagged / unknown line):
    /// Daniel, the male UK orchestrator voice.
    static let pulsarVoice = "Daniel"

    /// The LOCKED taxonomy + colours, plus a unique humanoid voice per character.
    /// Order is the canonical category list.
    ///
    /// Voice choices — persona + assumed gender → a distinct, genuinely humanoid
    /// ENGLISH voice installed on this machine. This box has only three humanoid
    /// Only DEFAULT-installed voices are used — ones macOS enumerates via
    /// AVSpeechSynthesisVoice (so `say` always finds them). Tara/Aman are NOT
    /// enumerated / are Siri-clashed, so they silently fell back to Daniel — hence
    /// this roster sticks to the seven reliable gendered English voices. Each is
    /// UNIQUE and matches the character's gender + aesthetic. Three male voices
    /// exist (Daniel, Rishi, Fred), so the three male characters are Pulsar,
    /// Voyager, Atlas; the four female voices go to the four female characters.
    ///   • pulsar   (M, orchestrator)         → Daniel   (en-GB) — authoritative conductor
    ///   • voyager  (M, rugged explorer)      → Fred     (en-US) — gruff, characterful (the
    ///     only remaining default male; a touch retro, which suits a rugged scout)
    ///   • sentinel (F, precise reviewer)     → Karen    (en-AU) — crisp, authoritative
    ///   • nova     (F, eager builder)        → Samantha (en-US) — bright, upbeat
    ///   • nebula   (F, artist)               → Moira    (en-IE) — warm, lyrical
    ///   • echo     (F, writer/communicator)  → Tessa    (en-ZA) — clear, articulate
    ///   • atlas    (M, sturdy generalist)    → Rishi    (en-IN) — deep, steady
    /// Colours: voyager/nova/nebula unchanged. echo/sentinel/atlas were
    /// re-separated (the old cyan/teal/slate blurred together) per the colour-
    /// distinctness review — echo → deeper teal, sentinel → bluer azure, atlas →
    /// a blue-leaning slate, so the three read as clearly different hues.
    /// Motion: each character moves to its persona — explorer restless+fast,
    /// reviewer near-still, builder bouncy, artist smooth/flowing, writer steady,
    /// generalist neutral.
    static let drones: [Drone] = [
        Drone(category: "voyager",  role: "explorer",   color: Color(red: 0.95, green: 0.66, blue: 0.23), voice: "Fred",     badge: "E",
              motion: MotionTrait(bobAmplitude: 3.4, bobFrequency: 1.35, activeScale: 2.5)),  // amber — restless, wide, fast
        Drone(category: "sentinel", role: "reviewer",   color: Color(red: 0.42, green: 0.72, blue: 0.92), voice: "Karen",    badge: "R",
              motion: MotionTrait(bobAmplitude: 0.8, bobFrequency: 0.6,  activeScale: 2.3)),  // azure — still, minimal
        Drone(category: "nova",     role: "builder",    color: Color(red: 0.36, green: 0.82, blue: 0.42), voice: "Samantha", badge: "B",
              motion: MotionTrait(bobAmplitude: 2.6, bobFrequency: 1.6,  activeScale: 2.45)), // green — busy, bouncy
        Drone(category: "nebula",   role: "artist",     color: Color(red: 0.91, green: 0.36, blue: 0.82), voice: "Moira",    badge: "A",
              motion: MotionTrait(bobAmplitude: 2.4, bobFrequency: 0.85, activeScale: 2.4)),  // magenta — smooth, flowing
        Drone(category: "echo",     role: "writer",     color: Color(red: 0.18, green: 0.75, blue: 0.72), voice: "Tessa",    badge: "W",
              motion: MotionTrait(bobAmplitude: 1.6, bobFrequency: 1.0,  activeScale: 2.4)),  // teal — steady
        Drone(category: "atlas",    role: "generalist", color: Color(red: 0.50, green: 0.55, blue: 0.80), voice: "Rishi",    badge: "G",
              motion: MotionTrait(bobAmplitude: 2.0, bobFrequency: 0.9,  activeScale: 2.4)),  // slate-blue — neutral
    ]

    /// Pulsar's own neutral motion trait, for when Pulsar drops to an orbit slot.
    static let pulsarMotion = MotionTrait(bobAmplitude: 2.0, bobFrequency: 0.9, activeScale: 2.4)

    /// The canonical category list (drone names only — Pulsar is not a drone).
    static let categories: [String] = drones.map(\.category)

    private static let byCategory: [String: Drone] =
        Dictionary(uniqueKeysWithValues: drones.map { ($0.category, $0) })

    /// Reverse of `voice(for:)` — each drone has a unique macOS voice, so a line's
    /// voice alone identifies its drone. Lets a pending queue thumbnail (which
    /// only carries the voice, not the category) render the right face instead of
    /// defaulting to Pulsar.
    private static let byVoice: [String: Drone] =
        Dictionary(drones.map { ($0.voice.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

    /// The drone category whose voice is `voice`, or nil for Pulsar's voice /
    /// anything unknown.
    static func category(forVoice voice: String) -> String? {
        byVoice[voice.lowercased()]?.category
    }

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

    /// The full drone record for a category, or nil for Pulsar / unknown.
    static func drone(for category: String?) -> Drone? {
        guard let category else { return nil }
        return byCategory[category.lowercased()]
    }

    /// The human-readable role for a category ("explorer", …); "" for Pulsar.
    static func role(for category: String?) -> String {
        drone(for: category)?.role ?? ""
    }

    /// The single-character role badge, or nil for Pulsar / unknown.
    static func badge(for category: String?) -> String? {
        drone(for: category)?.badge
    }

    /// The signature motion trait — the drone's own, else Pulsar's neutral one.
    static func motion(for category: String?) -> MotionTrait {
        drone(for: category)?.motion ?? pulsarMotion
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

/// The role label for a category ("explorer" …); "" for Pulsar / unknown.
func droneRole(for category: String?) -> String {
    DroneRegistry.role(for: category)
}

/// The role badge letter for a category, or nil for Pulsar / unknown.
func droneBadge(for category: String?) -> String? {
    DroneRegistry.badge(for: category)
}

/// The signature motion trait for a category (its own, else Pulsar's neutral).
func droneMotion(for category: String?) -> DroneRegistry.MotionTrait {
    DroneRegistry.motion(for: category)
}
