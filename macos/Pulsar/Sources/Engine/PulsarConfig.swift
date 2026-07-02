import Foundation

/// Singleton config store. Reads from:
///   1. REPO_ROOT/config.json — muted state, expletives toggle, native voice.
///   2. Environment variables — overrides for the native-voice choice + canon.
///
/// Thread-safe: all mutations go through an NSLock. Call `reload()` after
/// writing config.json to pick up new values without restarting the app.
final class PulsarConfig: @unchecked Sendable {
    static let shared = PulsarConfig()

    private let lock = NSLock()
    private var _config: [String: String] = [:]

    // MARK: - Init

    private init() {
        reload()
    }

    // MARK: - Paths

    /// Repo root: honour PULSAR_REPO_ROOT env var first, then default to
    /// ~/code/pulsar. This locates BUNDLED CODE ASSETS (e.g. the drone
    /// portrait frames under assets/portraits) — NOT mutable app state. Mutable
    /// state (config.json, cache/) lives under `storageRoot` in Application
    /// Support so the app works for DMG users with no checkout. Keep this here
    /// only for read-only asset lookups relative to the source tree.
    var repoRoot: URL {
        if let env = ProcessInfo.processInfo.environment["PULSAR_REPO_ROOT"],
           !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("code/pulsar")
    }

    /// Mutable app-state root. Defaults to a per-user Application Support dir
    /// (`~/Library/Application Support/Pulsar/`) so state lives OUTSIDE the code
    /// checkout — the app runs identically for DMG users with no source tree.
    /// Dev override: set `PULSAR_STORAGE` to point storage at a checkout's
    /// `cache/`+`config.json` instead.
    ///
    /// Directory is created on first access (best-effort).
    var storageRoot: URL {
        // Dev override wins.
        if let env = ProcessInfo.processInfo.environment["PULSAR_STORAGE"],
           !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Pulsar", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    var configPath: URL {
        storageRoot.appendingPathComponent("config.json")
    }

    var cacheDir: URL {
        storageRoot.appendingPathComponent("cache")
    }

    var phraseCacheDir: URL {
        cacheDir.appendingPathComponent("phrases")
    }

    /// Per-history-item audio retention store. Distinct from the phrase
    /// (dedupe) cache: EVERY played line is copied here keyed by its history
    /// id so `/history/replay` works for every entry, not just cache-eligible
    /// canon. Lifecycle-coupled to the in-memory history list (wiped at launch,
    /// evicted when an item drops off history) — see AudioQueueActor.
    var historyAudioDir: URL {
        cacheDir.appendingPathComponent("history")
    }

    // MARK: - Config values

    var isMuted: Bool {
        let val = lock.withLock { _config["PULSAR_MUTED"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    /// Whether Potty Mouth mode is on. Default OFF (Polite). When ON, canon
    /// picks from the potty pool and bespoke /speak lines are delivered as-is
    /// (no scrubbing). When OFF, bespoke lines are scrubbed clean before being
    /// cached or spoken, making Polite authoritative regardless of caller text.
    var expletivesEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_EXPLETIVES"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    /// The user's chosen local (free-mode) voice. Empty = auto (Daniel Enhanced
    /// when installed, else basic Daniel). Set via the Settings voice picker.
    var nativeVoiceChoice: String {
        (lock.withLock { _config["PULSAR_NATIVE_VOICE"] }
            ?? ProcessInfo.processInfo.environment["PULSAR_NATIVE_VOICE"]
            ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Whether the cached "canon" fallback is allowed — the Stop hook's
    /// turn-end floor for turns the model didn't compose a bespoke line on.
    /// Off = bespoke-only: only the model's freshly composed lines speak (the
    /// default register). Speech is free (local `say`), so this is a style
    /// choice, not a cost lever. Default on preserves today's behaviour.
    var canonEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_CANON_ENABLED"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    /// Whether the animated floating Pulsar head is shown on screen while it
    /// speaks. Default ON preserves today's behaviour. When OFF, the floating
    /// window is never created/shown (the voice still plays).
    var floatingHeadEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_FLOATING_HEAD"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    /// Whether the read-along caption bubble is shown below the floating head
    /// while it speaks. Default ON. Gated by `floatingHeadEnabled` at the view
    /// layer — head off means no bubble regardless of this flag.
    var subtitlesEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_SUBTITLES"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    /// Whether the orbiting/clustered sub-agent "drones" (the active-agent swarm)
    /// are shown. Default ON. When OFF only Pulsar himself appears; the drones'
    /// voices still play but no drone heads are rendered.
    var showActiveAgents: Bool {
        let val = lock.withLock { _config["PULSAR_SHOW_AGENTS"] } ?? "1"
        return !["0", "false", "no", "off", ""].contains(val.lowercased())
    }

    /// Whether Task Mode is enabled — shows the persistent Missions board tab in
    /// the popover. Default OFF (opt-in). Independent of the transient swarm.
    var taskModeEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_TASK_MODE"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    /// Whether AI-generated mission titles are enabled. Default OFF — local
    /// first-line naming is the canonical, fully-on-device default. When ON, the
    /// turn-start hook sends the session's first message to Claude (Haiku) to
    /// generate a short title that REPLACES the local name. A disclosed opt-in:
    /// the ONLY thing in Task Mode that leaves the machine, so it ships off.
    var llmTitlesEnabled: Bool {
        let val = lock.withLock { _config["PULSAR_LLM_TITLES"] } ?? "0"
        return ["1", "true", "yes", "on"].contains(val.lowercased())
    }

    // MARK: - Mutate + reload

    /// Read config.json from disk and coerce every value to a String, tolerating
    /// Bool/number values so one non-string value can't nuke the whole config (a
    /// bad hand-edit — or a Bool written by an older build — must not silently
    /// revert mute or persona). Returns nil only when the file is
    /// missing/unreadable/not-an-object, so callers can distinguish "no file" from
    /// "empty file". SHARED by `reload()` and `set()` — they must agree on the
    /// tolerant read, or a read-modify-write through a strict cast wipes siblings.
    private func loadCoerced() -> [String: String]? {
        guard let data = try? Data(contentsOf: configPath),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var coerced: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { coerced[k] = s }
            else if let b = v as? Bool { coerced[k] = b ? "1" : "0" }
            else if let n = v as? NSNumber { coerced[k] = n.stringValue }
        }
        return coerced
    }

    /// Re-read config.json from disk. Call after any write.
    func reload() {
        guard let coerced = loadCoerced() else { return }  // keep last-known, never blank
        lock.withLock { _config = coerced }
    }

    /// Write a single key back to config.json and reload. Reads the existing file
    /// with the SAME tolerant coercion as `reload()` (via `loadCoerced()`), so a
    /// sibling key holding a Bool/number value is preserved rather than wiped —
    /// the old strict `[String: String]` cast returned nil on any non-string
    /// value and clobbered every other key on the next write.
    func set(_ key: String, value: String) throws {
        var current = loadCoerced() ?? [:]
        current[key] = value
        let data = try JSONSerialization.data(withJSONObject: current, options: .prettyPrinted)
        try data.write(to: configPath)
        reload()
    }

    // MARK: - One-shot legacy migration (Caldwell → Pulsar / legacy dir)

    /// Legacy Application-Support dir the pre-rename `caldwell-speak` build wrote
    /// its state into. Sibling of `storageRoot` under the same Application Support
    /// root, so a `PULSAR_STORAGE` dev override redirects both in lockstep (the
    /// legacy dir is looked for beside wherever storage currently resolves).
    var legacyStorageRoot: URL {
        storageRoot.deletingLastPathComponent()
            .appendingPathComponent("caldwell-speak", isDirectory: true)
    }

    /// Sentinel marking the one-shot migration as done. Idempotency gates on THIS
    /// file's existence, never on key-presence — a user caught mid-hybrid (both
    /// CALDWELL_* and PULSAR_* keys live) must not re-run and clobber a newer
    /// PULSAR_* value the user re-toggled after the rename.
    private var migrationSentinel: URL {
        storageRoot.appendingPathComponent(".migrated")
    }

    /// One-shot, idempotent migration from the pre-rename `caldwell-speak` layout
    /// and from any lingering `CALDWELL_*` keys in the live config.
    ///
    /// MUST run BEFORE the server arms / `restoreInFlight()` and BEFORE the first
    /// `/settings` POST, so the merge can't race a live write. Wrapped in do/catch
    /// end-to-end: a failed migration NEVER blocks startup or corrupts the live
    /// config — worst case it's retried next launch (the sentinel is written last,
    /// only on success). Non-destructive: the legacy dir is COPIED, never moved.
    ///
    /// Rules:
    ///   • Gate on the `.migrated` sentinel. If present, no-op.
    ///   • If the new config.json is absent OR still carries `CALDWELL_*` keys,
    ///     seed from the legacy dir's config.json (+ cache/ if the new cache is
    ///     absent) by COPY.
    ///   • Rewrite every `CALDWELL_<X>` → `PULSAR_<X>`; on conflict the existing
    ///     `PULSAR_<X>` WINS (respects a post-rename re-toggle). Drop the old
    ///     `CALDWELL_*` keys.
    ///   • Persist via the hardened `set()`; write the sentinel LAST.
    func migrateLegacyConfigIfNeeded() {
        let fm = FileManager.default

        // Sentinel gate — already migrated, nothing to do.
        if fm.fileExists(atPath: migrationSentinel.path) { return }

        do {
            // Snapshot the current live config (tolerant read). nil = no file yet.
            let existing = loadCoerced()
            let hasLegacyKeys = (existing ?? [:]).keys.contains { $0.hasPrefix("CALDWELL_") }

            // Only do work if the new config is absent OR still half-migrated.
            // A fully-migrated config with no CALDWELL_* keys just gets a sentinel
            // so we never scan again.
            if existing != nil && !hasLegacyKeys {
                try? "ok".write(to: migrationSentinel, atomically: true, encoding: .utf8)
                return
            }

            // (1) Seed from the legacy dir if the new config is absent.
            let legacyConfig = legacyStorageRoot.appendingPathComponent("config.json")
            if existing == nil, fm.fileExists(atPath: legacyConfig.path) {
                // Copy the legacy config into place so loadCoerced() can read it.
                if fm.fileExists(atPath: configPath.path) { try? fm.removeItem(at: configPath) }
                try? fm.copyItem(at: legacyConfig, to: configPath)
            }

            // Copy the legacy cache/ if the new cache is absent (best-effort).
            let legacyCache = legacyStorageRoot.appendingPathComponent("cache", isDirectory: true)
            if !fm.fileExists(atPath: cacheDir.path), fm.fileExists(atPath: legacyCache.path) {
                try? fm.copyItem(at: legacyCache, to: cacheDir)
            }

            // (2) Load whatever config we now have (seeded or pre-existing).
            var merged = loadCoerced() ?? [:]

            // (3) Rewrite CALDWELL_<X> → PULSAR_<X>, PULSAR_ wins on conflict,
            //     drop the old keys.
            for (k, v) in merged where k.hasPrefix("CALDWELL_") {
                let newKey = "PULSAR_" + k.dropFirst("CALDWELL_".count)
                if merged[newKey] == nil {          // PULSAR_ wins on conflict
                    merged[newKey] = v
                }
                merged.removeValue(forKey: k)
            }

            // (4) Persist via the hardened writer, one key at a time, so the
            //     read-modify-write stays non-destructive throughout. Writing the
            //     full merged dict directly is fine too, but going through set()
            //     keeps a single write path and picks up the Fix-A tolerance.
            let data = try JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted)
            try data.write(to: configPath)
            reload()

            // (5) Sentinel LAST — only on success.
            try "ok".write(to: migrationSentinel, atomically: true, encoding: .utf8)
        } catch {
            // Never fatal: leave the live config as-is, no sentinel, retry next
            // launch. Startup proceeds regardless.
            NSLog("PulsarConfig: legacy migration skipped (\(error.localizedDescription))")
        }
    }
}

// Convenience — avoids `defer` boilerplate.
extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
