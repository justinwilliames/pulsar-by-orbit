import Foundation

/// Local macOS text-to-speech via the `say` CLI, synthesised to a temp AIFF so
/// it flows through the SAME envelope + afplay path as ElevenLabs — real
/// lip-sync, honest history, no special-casing. Free, fully local, no network:
/// the privacy/cost alternative to the cloud voice, and the never-silent
/// fallback when ElevenLabs fails.
enum NativeVoiceClient {

    /// Measured "butler" pace (words/min). Enhanced voices honour `-r`.
    static let defaultRate = 168

    /// Preferred British voice, best-first:
    ///   1. CALDWELL_FALLBACK_VOICE env override (escape hatch)
    ///   2. "Daniel (Enhanced)" — neural, closest to the Caldwell timbre
    ///   3. "Daniel" — the basic compact voice (always present on macOS)
    /// Re-resolved per call (cheap) so a freshly-installed Enhanced voice is
    /// picked up without an app restart. If Enhanced isn't installed we simply
    /// fall back to regular Daniel.
    static func bestVoice() -> String {
        if let override = ProcessInfo.processInfo.environment["CALDWELL_FALLBACK_VOICE"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        let names = installedVoiceNames()
        func has(_ wanted: String) -> String? {
            names.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        return has("Daniel (Enhanced)") ?? has("Daniel") ?? "Daniel"
    }

    /// Is the neural Enhanced Daniel installed? Drives the `/health` probe and
    /// the Settings install-status nudge.
    static func enhancedInstalled() -> Bool {
        installedVoiceNames().contains { $0.caseInsensitiveCompare("Daniel (Enhanced)") == .orderedSame }
    }

    /// `say`-usable voice names (the column before the locale in `say -v ?`).
    static func installedVoiceNames() -> [String] {
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
        var names: [String] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            // The name runs up to the first run of 2+ spaces (then the locale).
            if let r = s.range(of: "  ") {
                let name = String(s[s.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.append(name) }
            }
        }
        return names
    }

    /// Synthesise `text` to a temp AIFF and return its URL. Caller owns the file.
    /// Throws if `say` fails or produces no audio (caller then markFailed/last-ditch).
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
