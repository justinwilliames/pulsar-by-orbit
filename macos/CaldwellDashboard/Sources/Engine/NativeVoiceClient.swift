import AVFoundation
import Foundation

/// Local macOS text-to-speech. Synthesis runs via the `say` CLI to a temp AIFF
/// (so it flows through the same envelope + afplay path — real lip-sync); the
/// voice *catalogue* comes from `AVSpeechSynthesisVoice` (which carries gender +
/// quality, unlike `say -v ?`). Free, fully local, no network, no API key.
///
/// The catalogue is filtered + deduped for the picker:
///   • novelty voices (Bad News, Bells, Zarvox…) report `.unspecified` gender —
///     dropped entirely.
///   • a voice and its "(Enhanced)"/"(Premium)" variant collapse to ONE entry;
///     the app resolves to the highest-quality installed variant automatically
///     (so "Daniel" plays as "Daniel (Enhanced)" when that's downloaded).
enum NativeVoiceClient {

    /// Default speaking pace (words/min). Enhanced voices honour `-r`.
    static let defaultRate = 168

    /// A selectable voice for the picker: the deduped base name + a human label
    /// like "Daniel (English, UK)". `name` is the base; the daemon resolves it to
    /// the best installed variant at speak time.
    struct VoiceOption: Codable, Sendable {
        let name: String
        let label: String
    }

    /// Known macOS novelty/robotic voices, matched case-insensitively by base
    /// name. These report `.unspecified` gender so the human-voice filter in
    /// `compute()` drops them — but the Robotic category needs them, so they are
    /// re-added explicitly when installed. Keep in sync with the app-side
    /// `VoiceCategory.robotic` set in SettingsView.
    static let roboticVoiceNames: Set<String> = [
        "zarvox", "trinoids", "fred", "albert", "ralph", "whisper", "wobble",
        "bahh", "boing", "bells", "bubbles", "cellos", "organ", "jester",
        "superstar", "bad news", "good news",
    ]

    private struct ResolvedVoice {
        let display: String    // base name shown + stored, e.g. "Daniel"
        let resolved: String   // actual say -v name, e.g. "Daniel (Enhanced)"
        let label: String      // "Daniel (English, UK)"
        let language: String   // "en-GB"
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [ResolvedVoice]?

    @discardableResult
    private static func refresh() -> [ResolvedVoice] {
        let v = compute()
        lock.withLock { cached = v }
        return v
    }

    private static func voices() -> [ResolvedVoice] {
        if let v = (lock.withLock { cached }) { return v }
        return refresh()
    }

    /// Deduped base names — for validating a chosen voice.
    static func availableVoices() -> [String] { voices().map(\.display) }

    /// Picker options: one per voice, base name + "Name (Language, Region)".
    static func voiceOptions() -> [VoiceOption] {
        voices().map { VoiceOption(name: $0.display, label: $0.label) }
    }

    /// Is the Enhanced Daniel installed? Drives the install nudge.
    static func enhancedInstalled() -> Bool {
        AVSpeechSynthesisVoice.speechVoices().contains {
            $0.name.caseInsensitiveCompare("Daniel (Enhanced)") == .orderedSame
        }
    }

    /// The `say -v` name to actually speak with for the DEFAULT (Pulsar) voice:
    /// env override → Daniel (the fixed default) resolved to its best installed
    /// variant → first available. The user voice-picker is gone — every line is
    /// spoken in a character voice (Pulsar = Daniel, drones from the registry).
    static func bestVoice() -> String {
        if let override = ProcessInfo.processInfo.environment["CALDWELL_FALLBACK_VOICE"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        return resolved(base: DroneRegistry.pulsarVoice)
    }

    /// Resolve a base voice name (e.g. "Daniel", "Thomas", "Karen") to its best
    /// installed `say -v` variant (e.g. "Daniel (Enhanced)"). Falls back to the
    /// raw base name if it isn't in the catalogue — `say` may still know it even
    /// when `AVSpeechSynthesisVoice` doesn't enumerate it — and finally to
    /// Pulsar's Daniel, then anything installed.
    static func resolved(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let vs = voices()
        if !trimmed.isEmpty,
           let v = vs.first(where: { $0.display.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return v.resolved
        }
        // Not enumerated by AVSpeechSynthesisVoice — trust `say` to know the name
        // (it lists more voices than AVSpeech does). Use it verbatim.
        if !trimmed.isEmpty { return trimmed }
        if let daniel = vs.first(where: { $0.display.caseInsensitiveCompare("Daniel") == .orderedSame }) {
            return daniel.resolved
        }
        return vs.first?.resolved ?? "Daniel"
    }

    /// The `say -v` voice for a line tagged with drone `category`. Pulsar / nil /
    /// unknown → Daniel; a drone → its registry voice, each resolved to the best
    /// installed variant. An env override still wins (debug/global force).
    static func voice(forAgent category: String?) -> String {
        if let override = ProcessInfo.processInfo.environment["CALDWELL_FALLBACK_VOICE"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        return resolved(base: DroneRegistry.voice(for: category))
    }

    // MARK: - Private

    private static func compute() -> [ResolvedVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        // Real human voices only — macOS novelty voices report unspecified gender.
        let human = all.filter { $0.gender == .male || $0.gender == .female }

        func base(_ n: String) -> String {
            n.replacingOccurrences(of: " (Enhanced)", with: "")
             .replacingOccurrences(of: " (Premium)", with: "")
             .trimmingCharacters(in: .whitespaces)
        }
        func rank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
            switch q { case .premium: return 3; case .enhanced: return 2; default: return 1 }
        }

        struct Key: Hashable { let base: String; let lang: String }
        var groups: [Key: AVSpeechSynthesisVoice] = [:]
        for v in human {
            let k = Key(base: base(v.name), lang: v.language)
            if let ex = groups[k] {
                if rank(v.quality) > rank(ex.quality) { groups[k] = v }
            } else {
                groups[k] = v
            }
        }

        var resolved = groups.map { (k, v) in
            ResolvedVoice(display: k.base, resolved: v.name,
                          label: label(name: k.base, language: v.language), language: v.language)
        }

        // Re-add installed robotic/novelty voices. They report `.unspecified`
        // gender so the `human` filter above dropped them, but the Robotic voice
        // category needs them selectable. Dedupe against anything already present.
        let alreadyPresent = Set(resolved.map { $0.display.lowercased() })
        for v in all where roboticVoiceNames.contains(v.name.lowercased())
            && !alreadyPresent.contains(v.name.lowercased()) {
            resolved.append(ResolvedVoice(
                display: v.name, resolved: v.name,
                label: "\(v.name) (Robotic)", language: v.language))
        }

        // English first, then by language, then name.
        return resolved.sorted { a, b in
            let aEN = a.language.hasPrefix("en"), bEN = b.language.hasPrefix("en")
            if aEN != bEN { return aEN }
            if a.language != b.language { return a.language < b.language }
            return a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
        }
    }

    /// "Daniel (English, UK)" from a base name + "en-GB".
    private static func label(name: String, language: String) -> String {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        let langCode = parts.first.map(String.init) ?? ""
        let regionCode = parts.count > 1 ? String(parts[1]) : ""
        let lang = Locale.current.localizedString(forLanguageCode: langCode) ?? langCode
        let region: String
        switch regionCode {
        case "GB": region = "UK"
        case "US": region = "US"
        default:   region = Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode
        }
        if lang.isEmpty { return name }
        if region.isEmpty { return "\(name) (\(lang))" }
        return "\(name) (\(lang), \(region))"
    }

    /// Synthesise `text` to a temp AIFF and return its URL. Caller owns the file.
    /// `agent` selects the character voice: nil/"pulsar" → Daniel; a drone
    /// category → that drone's registry voice.
    static func synth(text: String, agent: String? = nil, rate: Int = defaultRate) async throws -> URL {
        let voice = voice(forAgent: agent)
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pulsar-native-\(UUID().uuidString).aiff")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Lead with a short silence so the very first phoneme isn't clipped by
        // `say` synthesis warm-up / afplay's audio-device startup — worst on a
        // voice's FIRST use (e.g. a drone speaking right after Pulsar, which is
        // exactly where the clipped-start was heard). afplay plays from byte 0, so
        // the startup latency now eats the silence instead of the first word. The
        // lip-sync envelope stays aligned (a closed-mouth lead-in of ~150ms).
        proc.arguments = ["-v", voice, "-r", String(rate), "-o", out.path, "[[slnc 150]] " + text]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task.detached { proc.waitUntilExit(); cont.resume() }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? nil
        guard proc.terminationStatus == 0, let bytes = size, bytes > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw NSError(domain: "NativeVoice", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "say synthesis failed (voice \(voice))"])
        }
        NSLog("[NativeVoice] ✓ \(voice) → '\(text.prefix(50))'")
        return out
    }
}
