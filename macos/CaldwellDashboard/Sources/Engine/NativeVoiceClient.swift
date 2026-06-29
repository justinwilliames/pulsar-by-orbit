import Foundation

/// Local macOS text-to-speech via the `say` CLI, synthesised to a temp AIFF so
/// it flows through the SAME envelope + afplay path as ElevenLabs — real
/// lip-sync, honest history, no special-casing. Free, fully local, no network:
/// the privacy/cost alternative to the cloud voice, and the never-silent
/// fallback when ElevenLabs fails.
///
/// IMPORTANT: the installed-voice probe (`say -v ?`) is a *blocking* Process +
/// pipe read. It must NEVER run on the async HTTP handler path (it starves the
/// Swift cooperative thread pool and wedges the server under concurrent polls).
/// So the probe result is cached; voice lookups only read the cache (self-
/// priming in the background), and only `synth()` and `prime()` — both off the
/// handler path — ever spawn `say`.
enum NativeVoiceClient {

    /// Measured "butler" pace (words/min). Enhanced voices honour `-r`.
    static let defaultRate = 168

    /// A selectable voice for the free-mode picker: the `say`-usable name plus a
    /// human label like "Daniel (English, UK)".
    struct VoiceOption: Codable, Sendable {
        let name: String
        let label: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedVoices: [(name: String, locale: String)]?

    /// Spawn `say -v ?` and cache (name, locale) pairs. Blocking — call only from
    /// a background task (auto-kicked lazily; safe at startup too).
    @discardableResult
    static func prime() -> [(name: String, locale: String)] {
        let voices = computeVoices()
        lock.withLock { cachedVoices = voices }
        return voices
    }

    private static func voices() -> [(name: String, locale: String)] {
        if let v = (lock.withLock { cachedVoices }) { return v }
        Task.detached { _ = prime() }
        return []
    }

    /// `say`-usable voice names. Cached; safe on the handler path.
    static func names() -> [String] { voices().map(\.name) }

    /// Voice names for validation (free-mode picker accepts only these).
    static func availableVoices() -> [String] { names() }

    /// Rich options for the picker: each name plus a "Name (Language, Region)"
    /// label. English/British voices first, then the rest, alphabetical.
    static func voiceOptions() -> [VoiceOption] {
        let opts = voices().map { VoiceOption(name: $0.name, label: label(name: $0.name, locale: $0.locale)) }
        return opts.sorted { a, b in
            let aEN = a.label.contains("English"), bEN = b.label.contains("English")
            if aEN != bEN { return aEN }      // English first
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Preferred voice, best-first: env override → user pick (if installed) →
    /// "Daniel (Enhanced)" → "Daniel".
    static func bestVoice() -> String {
        if let override = ProcessInfo.processInfo.environment["CALDWELL_FALLBACK_VOICE"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        let n = names()
        func has(_ wanted: String) -> String? {
            n.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        let choice = CaldwellConfig.shared.nativeVoiceChoice
        if !choice.isEmpty, let picked = has(choice) { return picked }
        return has("Daniel (Enhanced)") ?? has("Daniel") ?? "Daniel"
    }

    static func enhancedInstalled() -> Bool {
        names().contains { $0.caseInsensitiveCompare("Daniel (Enhanced)") == .orderedSame }
    }

    // MARK: - Private

    /// `say -v ?` → (name, locale) pairs. Blocking.
    private static func computeVoices() -> [(name: String, locale: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = ["-v", "?"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        // Each line: "<name>   <lang>_<REGION>   # sample". The locale token is
        // the anchor; the name is everything before it.
        let re = try? NSRegularExpression(pattern: "\\b([a-z]{2,3})[-_]([A-Z]{2})\\b")
        var result: [(String, String)] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            let ns = s as NSString
            guard let re,
                  let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
            else { continue }
            let locale = ns.substring(with: m.range)
            let name = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result.append((name, locale)) }
        }
        return result
    }

    /// "Daniel (English, UK)" from a name + "en_GB".
    private static func label(name: String, locale: String) -> String {
        let parts = locale.replacingOccurrences(of: "-", with: "_").split(separator: "_")
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
    static func synth(text: String, rate: Int = defaultRate) async throws -> URL {
        let voice = bestVoice()
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("caldwell-native-\(UUID().uuidString).aiff")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = ["-v", voice, "-r", String(rate), "-o", out.path, text]
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
