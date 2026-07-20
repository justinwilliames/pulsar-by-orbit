import SwiftUI

struct Voice: Codable, Identifiable, Hashable {
    let name: String
    let id: String
    let color: String
    let style: String

    var swiftUIColor: Color {
        Color(hex: color) ?? .blue
    }
}

/// Navigation aid for the voice picker: splits the installed voices into two
/// buckets so the list is browsable. Categorisation is purely by voice NAME,
/// app-side — no daemon change needed. A small, fixed set of macOS novelty
/// voices is "Robotic"; EVERYTHING ELSE (including unknown/new voices) is
/// "Humanoid", so the default for anything unrecognised is Humanoid.
enum VoiceCategory: String, CaseIterable, Identifiable {
    case robotic = "Robotic"
    case humanoid = "Humanoid"

    var id: String { rawValue }

    /// The default voice for each category. Out-of-box, Pulsar opens on Robotic
    /// with Trinoids selected (native rate, no tuning); the Humanoid default is
    /// Daniel.
    var defaultVoiceName: String {
        switch self {
        case .robotic: return "Trinoids"
        case .humanoid: return "Daniel"
        }
    }

    /// Robotic voice base names, matched case-insensitively. Keep in sync with
    /// `NativeVoiceClient.roboticVoiceNames`.
    private static let roboticNames: Set<String> = [
        "zarvox", "trinoids", "fred", "albert", "ralph", "whisper", "wobble",
        "bahh", "boing", "bells", "bubbles", "cellos", "organ", "jester",
        "superstar", "bad news", "good news", "junior", "kathy",
    ]

    /// Categorise a voice by its (base) name. Anything not in the robotic set —
    /// including unknown or newly-installed voices — falls through to Humanoid.
    static func category(for voiceName: String) -> VoiceCategory {
        let key = voiceName
            .replacingOccurrences(of: " (Enhanced)", with: "")
            .replacingOccurrences(of: " (Premium)", with: "")
            .replacingOccurrences(of: " (Robotic)", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return roboticNames.contains(key) ? .robotic : .humanoid
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8) & 0xFF) / 255,
            blue: Double(val & 0xFF) / 255
        )
    }
}
