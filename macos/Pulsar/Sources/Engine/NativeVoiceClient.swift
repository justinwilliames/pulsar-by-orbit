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
///   • a voice and its "(Enhanced)"/"(Premium)" variant collapse to ONE entry
///     under the BASE name. The app speaks the BASE variant by default (always
///     present on a stock Mac); the Enhanced/Premium variant — a manual download
///     absent on most machines — is only spoken when the user EXPLICITLY opts
///     into it (see `resolvedRespectingChoice`).
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
        let display: String    // base name shown + stored + spoken, e.g. "Daniel"
        let resolved: String   // best installed variant, e.g. "Daniel (Enhanced)" — used
                               // ONLY when the user explicitly opted into it
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
        if let override = ProcessInfo.processInfo.environment["PULSAR_FALLBACK_VOICE"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        // Default = base Daniel (always present); an explicit Enhanced/Premium
        // opt-in via PULSAR_NATIVE_VOICE is honoured, otherwise base.
        return resolvedRespectingChoice(base: DroneRegistry.pulsarVoice)
    }

    /// Resolve a base voice name (e.g. "Daniel", "Thomas", "Karen") to the `say -v`
    /// name to actually speak with.
    ///
    /// DEFAULT = the BASE name, never the "(Enhanced)"/"(Premium)" variant.
    /// Enhanced/Premium voices are a MANUAL macOS download; a stock Mac does not
    /// have them, so resolving to `Daniel (Enhanced)` (the old behaviour) made
    /// `say -v "Daniel (Enhanced)"` fail / fall back on most machines. The base
    /// `Daniel` is guaranteed present on a stock macOS, so it's always the safe
    /// default and fallback.
    ///
    /// The ONLY time we speak an Enhanced/Premium variant is when the user has
    /// EXPLICITLY chosen it (their `nativeVoiceChoice` names that exact variant,
    /// e.g. "Daniel (Enhanced)") AND it's installed — honoured by
    /// `resolvedRespectingChoice`, not here.
    ///
    /// Falls back to the raw base name if it isn't in the catalogue — `say` may
    /// still know it even when `AVSpeechSynthesisVoice` doesn't enumerate it —
    /// and finally to Pulsar's Daniel, then anything installed (base name).
    static func resolved(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let vs = voices()
        if !trimmed.isEmpty,
           let v = vs.first(where: { $0.display.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return v.display
        }
        // Not enumerated by AVSpeechSynthesisVoice — trust `say` to know the name
        // (it lists more voices than AVSpeech does). Use it verbatim.
        if !trimmed.isEmpty { return trimmed }
        if let daniel = vs.first(where: { $0.display.caseInsensitiveCompare("Daniel") == .orderedSame }) {
            return daniel.display
        }
        return vs.first?.display ?? "Daniel"
    }

    /// The base name resolved for a chosen voice, but honouring an EXPLICIT
    /// user opt-in to a specific installed Enhanced/Premium variant.
    ///
    /// If the user's `PULSAR_NATIVE_VOICE` names an exact installed `say -v`
    /// variant (base OR Enhanced/Premium), speak THAT verbatim. Otherwise fall
    /// through to `resolved(base:)`, which always returns a base name. This is
    /// what lets a user who deliberately downloaded + selected "Daniel
    /// (Enhanced)" get it, while every out-of-box user speaks the base "Daniel".
    static func resolvedRespectingChoice(base: String) -> String {
        let choice = PulsarConfig.shared.nativeVoiceChoice
        if !choice.isEmpty,
           AVSpeechSynthesisVoice.speechVoices().contains(where: {
               $0.name.caseInsensitiveCompare(choice) == .orderedSame
           }) {
            return choice
        }
        return resolved(base: base)
    }

    /// The `say -v` voice for a line tagged with drone `category`. Pulsar / nil /
    /// unknown → Daniel; a drone → its registry voice, each resolved to the best
    /// installed variant. An env override still wins (debug/global force).
    static func voice(forAgent category: String?) -> String {
        if let override = ProcessInfo.processInfo.environment["PULSAR_FALLBACK_VOICE"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        return englishResolved(base: DroneRegistry.voice(for: category))
    }

    /// Resolve a base voice but GUARANTEE it speaks English. The floating heads
    /// are English-only: if a base name resolves to a non-English voice — or can't
    /// be verified as English (e.g. an ambiguous name that `say` might bind to a
    /// non-English / Siri variant) — fall back to Pulsar's Daniel rather than let a
    /// drone speak another language or garble. Every drone voice in the registry is
    /// a standard English voice, so this only ever triggers on a mis-set / clashing
    /// voice — exactly the failure we're guarding against.
    static func englishResolved(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let vs = voices()
        if let v = vs.first(where: { $0.display.caseInsensitiveCompare(trimmed) == .orderedSame }),
           v.language.hasPrefix("en") {
            // Base name, not the Enhanced/Premium variant — see `resolved(base:)`.
            return v.display
        }
        // Not found as an English voice → force Daniel (always English, base).
        return resolved(base: DroneRegistry.pulsarVoice)
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
        // Wait for `say` WITHOUT parking a cooperative-pool thread. The old
        // `Task.detached { proc.waitUntilExit() }` blocked a pool thread per
        // synth on a syscall — reintroducing the exact pool-exhaustion stall the
        // afplay terminationHandler fix already solved for playback. Resume the
        // continuation from `terminationHandler` (fired by Foundation off the
        // pool) instead. The handler is set BEFORE `run()`; if `run()` throws it
        // never fires, so we resume manually to avoid leaking the continuation.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { _ in cont.resume() }
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                cont.resume(throwing: error)
            }
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
