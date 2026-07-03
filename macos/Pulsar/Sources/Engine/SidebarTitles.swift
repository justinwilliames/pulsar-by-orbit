import Foundation

/// Resolves a Claude Code `cliSessionId` → the REAL Claude Desktop sidebar title,
/// entirely LOCALLY from the app's on-disk session index — no network, no egress.
///
/// Claude Desktop persists each session's sidebar name at
///   ~/Library/Application Support/Claude/claude-code-sessions/<…>/local_*.json
/// Each such file is JSON carrying (at least) `cliSessionId` (a UUID that EQUALS
/// our board's `session_id`), `title` (the sidebar name), `titleSource`, and
/// `lastActivityAt`. This resolver scans those files and builds a
/// `cliSessionId → title` map so a Missions row can show what the mission
/// actually is.
///
/// Cheap + thread-safe: the map is rebuilt at most once per ~15s behind a lock,
/// and `title(for:)` serves the cached map otherwise. Best-effort throughout —
/// any per-file parse/IO error is skipped; a missing base dir yields an empty
/// map; nothing here ever throws.
final class SidebarTitles {
    /// Shared process-wide resolver.
    static let shared = SidebarTitles()

    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var lastBuilt: Date = .distantPast

    /// How long a built map is served before the next `title(for:)` rebuilds it.
    private let ttl: TimeInterval = 15

    /// The Claude Desktop sessions root, or nil when Application Support is
    /// unavailable. Resolved once — the path is stable for the app's lifetime.
    private let baseDir: URL?

    init() {
        self.baseDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
    }

    /// The sidebar title for a board `session_id` (== `cliSessionId`), or nil when
    /// no local session file names it. Triggers a rebuild if the cache is older
    /// than the TTL; otherwise serves the cached map. Never throws.
    func title(for sessionId: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(lastBuilt) > ttl {
            cache = Self.buildMap(baseDir: baseDir)
            lastBuilt = Date()
        }
        return cache[sessionId]
    }

    /// Scan `baseDir` recursively for `local_*.json` files and build the
    /// `cliSessionId → title` map. On a duplicate cliSessionId, keep the entry
    /// with the greater `lastActivityAt` (falling back to file modificationDate).
    /// Any error on a single file skips just that file; a nil/absent base dir
    /// gives an empty map.
    private static func buildMap(baseDir: URL?) -> [String: String] {
        guard let baseDir else { return [:] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: baseDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [:] }

        var map: [String: String] = [:]
        // Tracks the freshness score behind each winning entry, so a later,
        // staler file for the same cliSessionId can't clobber a fresher one.
        var freshness: [String: Double] = [:]

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }

            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cliSessionId = obj["cliSessionId"] as? String, !cliSessionId.isEmpty,
                  let title = obj["title"] as? String, !title.isEmpty
            else { continue }

            // Freshness: prefer the file's lastActivityAt (a Number); fall back to
            // the filesystem modificationDate; else treat as oldest possible.
            let score: Double
            if let activity = (obj["lastActivityAt"] as? NSNumber)?.doubleValue {
                score = activity
            } else if let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                score = mod.timeIntervalSince1970
            } else {
                score = -.greatestFiniteMagnitude
            }

            if let existing = freshness[cliSessionId], existing >= score { continue }
            map[cliSessionId] = title
            freshness[cliSessionId] = score
        }
        return map
    }
}
