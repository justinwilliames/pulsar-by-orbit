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
/// So the probe result is cached; `bestVoice()`/`enhancedInstalled()` only read
/// the cache (self-priming in the background), and only `synth()` and `prime()`
/// — both off the handler path — ever spawn `say`.
enum NativeVoiceClient {

    /// Measured "butler" pace (words/min). Enhanced voices honour `-r`.
    static let defaultRate = 168

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedNames: [String]?

    /// Spawn `say -v ?` and cache the installed voice names. Blocking — call
    /// only from a background task (it's auto-kicked lazily; safe to call at
    /// startup too).
    @discardableResult
    static func prime() -> [String] {
        let names = computeVoiceNames()
        lock.withLock { cachedNames = names }
        return names
    }

    /// Cached voice names. If not yet primed, kick a background prime and return
    /// empty for now (handlers fall back to "Daniel" until the probe lands —
    /// ~0.3s — never blocking).
    private static func names() -> [String] {
        if let n = (lock.withLock { cachedNames }) { return n }
        Task.detached { _ = prime() }
        return []
    }

    /// Preferred British voice, best-first: env override → "Daniel (Enhanced)"
    /// (neural, closest to the Caldwell timbre) → "Daniel" (always present). If
    /// Enhanced isn't installed we simply fall back to regular Daniel.
    static func bestVoice() -> String {
        if let override = ProcessInfo.processInfo.environment["CALDWELL_FALLBACK_VOICE"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        let n = names()
        func has(_ wanted: String) -> String? {
            n.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        // The user's explicit pick from the free-mode voice picker, if installed.
        let choice = CaldwellConfig.shared.nativeVoiceChoice
        if !choice.isEmpty, let picked = has(choice) { return picked }
        return has("Daniel (Enhanced)") ?? has("Daniel") ?? "Daniel"
    }

    /// All `say`-usable installed voices, for the free-mode voice picker. Cached.
    /// (Apple's true Siri voices are reserved by the system and never appear
    /// here — they can't be driven by `say` or AVSpeechSynthesizer.)
    static func availableVoices() -> [String] { names() }

    /// Is the neural Enhanced Daniel installed? Drives the `/health` probe and
    /// the Settings install-status nudge. Reads cache only.
    static func enhancedInstalled() -> Bool {
        names().contains { $0.caseInsensitiveCompare("Daniel (Enhanced)") == .orderedSame }
    }

    /// `say -v ?` → the usable voice names (column before the locale). Blocking.
    private static func computeVoiceNames() -> [String] {
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
        var result: [String] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            if let r = s.range(of: "  ") {
                let name = String(s[s.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { result.append(name) }
            }
        }
        return result
    }

    /// Synthesise `text` to a temp AIFF and return its URL. Caller owns the file.
    /// Throws if `say` fails or produces no audio. Runs in a detached fetch task,
    /// so the blocking wait never touches the handler path.
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
