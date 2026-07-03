import Foundation

/// One tracked Claude Code session on the Missions board. A session is the main
/// orchestrator turn; its sub-agent drones nest beneath it in the UI. `phase`
/// distinguishes a turn in progress ("working") from one that ended and is
/// waiting on the user ("waiting" → "Needs you").
struct SessionRecord: Codable, Sendable {
    var sessionId: String
    var label: String
    var lastSeen: Date
    var phase: String  // "working" | "waiting"
    var dismissed: Bool
    /// When the USER last sent a message in this session (UserPromptSubmit). This
    /// — NOT lastSeen — drives the 7-day recency window and the board sort, so
    /// drone/speak/Stop churn can't keep a stale session "recent". Optional so a
    /// store written by an older build (no such field) still decodes.
    var lastUserMessage: Date?
    /// Sticky session name — the session's FIRST user message (truncated). Set
    /// once and never overwritten, so the board title stays stable across a
    /// session's many turns. Optional (older stores + pre-first-message sessions).
    var name: String?
    /// The session's current git branch (from the turn-start hook). LIVE context,
    /// NOT sticky — a mid-session branch switch tracks. Optional: a non-git cwd
    /// (or an older store) simply has none, and the UI falls back to the label.
    var branch: String?
    /// The git repo name (toplevel basename) for the session. LIVE, best-effort;
    /// a fuller project label than the raw cwd basename when the two differ.
    var repo: String?
    /// A short single-line snippet of the LAST assistant message (from the Stop
    /// hook). LIVE, updated every turn — the highest-signal per-row discriminator
    /// ("what this session just did"), unlike the sticky first-message name.
    var lastAction: String?
    /// True once the USER manually renamed this session. A user name OUTRANKS
    /// every auto-source (first-message, LLM titler, branch) and is permanent —
    /// the LLM titler can never clobber it on a later turn. Optional (older
    /// stores + never-renamed sessions decode as nil == false).
    var userNamed: Bool?
    /// The last time the PreToolUse heartbeat fired for this session — i.e. the
    /// session was actively using a tool. LIVE, not sticky. The board reads this
    /// (freshness-windowed) to PULSE the parent as "working now", distinct from
    /// the phase pill (which is set at turn-start and only cleared at Stop, so it
    /// falsely reads "working" for an idle-but-unstopped session). Optional.
    var lastActiveAt: Date?
    /// A short (≤40 char) description of what the session is doing RIGHT NOW
    /// ("Editing MissionsView.swift", "Running: swift build") — from the
    /// PreToolUse heartbeat. LIVE; paired with lastActiveAt. Optional.
    var currentAction: String?
    /// The drone category matching the current live work ("voyager"|"nova"|
    /// "pulsar") — so the board can tint the action line + pulse in the right
    /// hue. LIVE; paired with lastActiveAt. Optional.
    var activeCategory: String?

    enum CodingKeys: String, CodingKey {
        case sessionId, label, lastSeen, phase, dismissed, lastUserMessage, name
        case branch, repo, lastAction, userNamed
        case lastActiveAt, currentAction, activeCategory
    }

    init(sessionId: String, label: String, lastSeen: Date, phase: String, dismissed: Bool, lastUserMessage: Date?, name: String?, branch: String? = nil, repo: String? = nil, lastAction: String? = nil, userNamed: Bool? = nil, lastActiveAt: Date? = nil, currentAction: String? = nil, activeCategory: String? = nil) {
        self.sessionId = sessionId
        self.label = label
        self.lastSeen = lastSeen
        self.phase = phase
        self.dismissed = dismissed
        self.lastUserMessage = lastUserMessage
        self.name = name
        self.branch = branch
        self.repo = repo
        self.lastAction = lastAction
        self.userNamed = userNamed
        self.lastActiveAt = lastActiveAt
        self.currentAction = currentAction
        self.activeCategory = activeCategory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.label = try c.decode(String.self, forKey: .label)
        self.lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        self.phase = try c.decode(String.self, forKey: .phase)
        self.dismissed = try c.decode(Bool.self, forKey: .dismissed)
        self.lastUserMessage = try c.decodeIfPresent(Date.self, forKey: .lastUserMessage)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        // decodeIfPresent for all four so an OLD store (written before these
        // fields existed) still decodes cleanly — they arrive as nil.
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.repo = try c.decodeIfPresent(String.self, forKey: .repo)
        self.lastAction = try c.decodeIfPresent(String.self, forKey: .lastAction)
        self.userNamed = try c.decodeIfPresent(Bool.self, forKey: .userNamed)
        // Live heartbeat fields — decodeIfPresent so an OLD store (pre-heartbeat)
        // still decodes; they arrive as nil and simply read as "not active".
        self.lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        self.currentAction = try c.decodeIfPresent(String.self, forKey: .currentAction)
        self.activeCategory = try c.decodeIfPresent(String.self, forKey: .activeCategory)
    }
}

/// Persisted actor tracking recently-active Claude Code sessions for the
/// Missions board. Mirrors AudioQueueActor's on-disk store idiom: load on init,
/// write after each mutation, atomic writes under `PulsarConfig.storageRoot`.
///
/// A session is `note()`d on turn start (working), sub-agent start/stop
/// (working), any tagged speak line (working), and turn end (waiting). The board
/// shows sessions active in the last 7 days that the user hasn't dismissed.
actor SessionRegistry {
    static let shared = SessionRegistry()

    private var sessions: [String: SessionRecord] = [:]

    /// Test seam: when set, the store lives here instead of the real
    /// `storageRoot/sessions.json`. nil in production.
    private let storeOverrideURL: URL?

    private var storeURL: URL {
        storeOverrideURL
            ?? PulsarConfig.shared.storageRoot.appendingPathComponent("sessions.json")
    }

    /// Default window: a session is shown if it was seen within the last 7 days
    /// and hasn't been dismissed.
    static let activeWindow: TimeInterval = 7 * 24 * 3600

    // MARK: - Retention bounds
    //
    // The board only ever SHOWS sessions within `activeWindow` (7 days). These
    // bounds are the store's actual RETENTION policy — without them the on-disk
    // map grew forever (a read-time filter is not a retention policy). They run
    // on load and before every persist, so the file can never grow unbounded.

    /// Hard TTL for a live (non-dismissed) record. Well past the 7-day display
    /// window, so a record is only physically dropped long after it stopped
    /// showing — never yanking a session the user might still see.
    static let liveTTL: TimeInterval = 14 * 24 * 3600

    /// A dismissed record is a tombstone — kept only long enough to keep a
    /// session hidden through its trailing machine churn (Stop hook, drone stop,
    /// /speak). After 24h it's genuinely gone; a brand-new note() would re-add it.
    static let dismissedTTL: TimeInterval = 24 * 3600

    /// Absolute cap on stored records. Beyond this, the oldest by `lastSeen` are
    /// evicted first. A safety valve against pathological churn (many one-off
    /// session ids) even inside the TTL window.
    static let maxRecords = 200

    init(storeOverrideURL: URL? = nil) {
        self.storeOverrideURL = storeOverrideURL
        load()
    }

    // MARK: - Mutations

    /// Upsert a session's activity. Refreshes `lastSeen`; sets `phase` when
    /// given; derives `label` from `cwd`'s last path component when supplied.
    /// ALWAYS un-hides the session (new activity clears a prior dismiss). Persists.
    ///
    /// `isUserMessage` = true ONLY for a real UserPromptSubmit (the user just sent
    /// a message). It sets `lastUserMessage`, which is the SOLE driver of the
    /// 7-day window + board sort. Machine churn (drone start/stop, /speak, the
    /// Stop hook) calls with the default false — it updates phase/status but never
    /// moves the window, so a session can't stay "recent" without the user.
    /// `nameOverride` = true ONLY from the LLM-titler path. Normally the name is
    /// STICKY (first non-empty wins) so a mission title stays stable across a
    /// session's turns. The local sync POST seeds a first-line name immediately;
    /// the opt-in LLM title then arrives with `nameOverride: true` to REPLACE
    /// that one seed. Still never overwrites with an empty name.
    ///
    /// `userNamed` = true ONLY from a manual user rename. It sets the name AND
    /// latches `record.userNamed`, which OUTRANKS everything: once a human has
    /// named a session, no later `nameOverride` (the LLM titler) may clobber it.
    /// This closes the known bug where the opt-in titler silently erased a human
    /// title on the next turn.
    ///
    /// `branch`/`repo`/`lastAction` are LIVE context (not sticky) — the freshest
    /// non-empty value always wins, so a branch switch or a new last-action tracks.
    ///
    /// `activeNow` = true ONLY from the PreToolUse heartbeat (a MAIN session is
    /// firing a tool RIGHT NOW). It stamps `lastActiveAt = Date()` and refreshes
    /// `currentAction`/`activeCategory`, but deliberately DOES NOT touch phase,
    /// lastUserMessage, or dismissed — it is a pure liveness ping, not a turn/user
    /// event. `lastSeen` is still refreshed (as for any note) so a live session
    /// never ages out of the store.
    func note(sessionId: String, cwd: String?, phase: String?, isUserMessage: Bool = false, name: String? = nil, nameOverride: Bool = false, userNamed: Bool = false, branch: String? = nil, repo: String? = nil, lastAction: String? = nil, activeNow: Bool = false, currentAction: String? = nil, activeCategory: String? = nil) {
        let trimmedId = sessionId.trimmingCharacters(in: .whitespaces)
        guard !trimmedId.isEmpty else { return }

        let derivedLabel = cwd
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
        let trimmedName = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let trimmedBranch = branch.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let trimmedRepo = repo.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let trimmedAction = lastAction.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let trimmedCurrentAction = currentAction.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let trimmedActiveCategory = activeCategory.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        if var existing = sessions[trimmedId] {
            existing.lastSeen = Date()
            if let phase, !phase.isEmpty { existing.phase = phase }
            if let derivedLabel, !derivedLabel.isEmpty { existing.label = derivedLabel }
            if isUserMessage { existing.lastUserMessage = Date() }
            // LIVE context — always take the freshest non-empty value.
            if let trimmedBranch { existing.branch = trimmedBranch }
            if let trimmedRepo { existing.repo = trimmedRepo }
            if let trimmedAction { existing.lastAction = trimmedAction }
            // LIVE heartbeat — a PreToolUse ping stamps activity WITHOUT touching
            // phase / lastUserMessage / dismissed (see the note() docstring).
            if activeNow {
                existing.lastActiveAt = Date()
                existing.currentAction = trimmedCurrentAction
                existing.activeCategory = trimmedActiveCategory
            }
            // Name precedence (highest → lowest):
            //   1. a user rename latches userNamed and always wins;
            //   2. once userNamed, NOTHING (not even the LLM `nameOverride`) may
            //      overwrite — the human title is permanent;
            //   3. the LLM titler (`nameOverride`) may replace the local seed;
            //   4. otherwise STICKY: first non-empty wins, later turns don't churn.
            // Never overwrite with an empty name.
            if let trimmedName {
                if userNamed {
                    existing.name = trimmedName
                    existing.userNamed = true
                } else if (existing.userNamed ?? false) {
                    // A human already named it — ignore auto sources entirely.
                } else if nameOverride || (existing.name ?? "").isEmpty {
                    existing.name = trimmedName
                }
            }
            // A dismiss STICKS through the trailing machine churn (Stop hook,
            // drone stop, /speak). ONLY a genuine new user message un-hides a
            // session — sending it a message IS returning to it. So machine
            // note() calls leave `dismissed` untouched.
            if isUserMessage { existing.dismissed = false }
            sessions[trimmedId] = existing
            schedulePersist()
        } else {
            // A brand-new session is never dismissed. (A dismiss can't precede
            // the first note — dismiss() no-ops on an unknown id.)
            let label = derivedLabel ?? "#" + String(trimmedId.prefix(4))
            sessions[trimmedId] = SessionRecord(
                sessionId: trimmedId,
                label: label,
                lastSeen: Date(),
                phase: (phase?.isEmpty == false ? phase! : "working"),
                dismissed: false,
                lastUserMessage: isUserMessage ? Date() : nil,
                name: trimmedName,
                branch: trimmedBranch,
                repo: trimmedRepo,
                lastAction: trimmedAction,
                // A brand-new session created BY a rename latches userNamed so the
                // human title holds even here (edge case: rename before any turn).
                userNamed: userNamed ? true : nil,
                // Edge case: a heartbeat arrives before turn-start ever created the
                // record. Stamp liveness so the very first tool call already pulses.
                lastActiveAt: activeNow ? Date() : nil,
                currentAction: activeNow ? trimmedCurrentAction : nil,
                activeCategory: activeNow ? trimmedActiveCategory : nil)
            schedulePersist()
        }
    }

    /// Hide a session from the board. Persists. New activity via `note()` unhides.
    func dismiss(sessionId: String) {
        let trimmedId = sessionId.trimmingCharacters(in: .whitespaces)
        guard sessions[trimmedId] != nil else { return }
        sessions[trimmedId]?.dismissed = true
        schedulePersist()
    }

    // MARK: - Reads

    /// Non-dismissed sessions to show on the board.
    ///
    /// The window keys on `lastUserMessage` (the user's own activity), NOT
    /// `lastSeen` — so drone/speak/Stop churn can't keep a session on the board
    /// without the user messaging. A session qualifies when it is not dismissed
    /// AND either:
    ///   • the user messaged it within `seconds` (the 7-day window), OR
    ///   • it currently has ≥1 in-flight drone (`liveSessionIds`) — the guard so
    ///     live work never vanishes, even before the first user message lands or
    ///     after the window would otherwise expire mid-run.
    ///
    /// Sort: by `lastUserMessage` desc, treating nil as "now" so a live-but-
    /// unmessaged session floats to the top rather than sinking.
    func activeSessions(
        within seconds: TimeInterval = SessionRegistry.activeWindow,
        liveSessionIds: Set<String> = []
    ) -> [SessionRecord] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-seconds)
        return sessions.values
            .filter { record in
                guard !record.dismissed else { return false }
                let recentByUser = (record.lastUserMessage.map { $0 > cutoff }) ?? false
                let isLive = liveSessionIds.contains(record.sessionId)
                return recentByUser || isLive
            }
            .sorted { ($0.lastUserMessage ?? now) > ($1.lastUserMessage ?? now) }
    }

    // MARK: - Retention

    /// Drop records that have aged past their TTL, then enforce the hard cap by
    /// evicting the oldest-by-`lastSeen` beyond `maxRecords`. Idempotent and
    /// cheap; runs on load and before every persist so the store is bounded on
    /// disk, not just filtered at read time.
    ///
    /// A live-but-unmessaged session is safe here: TTL keys on `lastSeen`, which
    /// every drone/speak note() refreshes, so a running session is always the
    /// newest and never at TTL or cap risk. (An in-flight drone can't be reached
    /// from this actor without a hop; TTL+cap alone suffice — see item 1 spec.)
    private func prune(now: Date = Date()) {
        sessions = sessions.filter { _, record in
            let age = now.timeIntervalSince(record.lastSeen)
            if record.dismissed { return age <= Self.dismissedTTL }
            return age <= Self.liveTTL
        }
        if sessions.count > Self.maxRecords {
            let overflow = sessions.count - Self.maxRecords
            let evict = sessions.values
                .sorted { $0.lastSeen < $1.lastSeen }   // oldest first
                .prefix(overflow)
                .map(\.sessionId)
            for id in evict { sessions.removeValue(forKey: id) }
        }
    }

    // MARK: - Persistence

    /// True while a coalesced persist is already scheduled, so a burst of
    /// mutations collapses to ONE prune+write of the final state rather than
    /// one blocking fsync per note()/dismiss(). Mirrors AudioQueueActor.
    private var persistScheduled = false

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: SessionRecord].self, from: data)
        else { return }
        sessions = decoded
        // Prune stale/over-cap records inherited from a prior run, and rewrite
        // the normalised store so a long-dead file self-heals on first launch.
        let before = sessions.count
        prune()
        if sessions.count != before { schedulePersist() }
    }

    /// Mark the store dirty and schedule a single coalesced write off the hot
    /// path. The actor hop means any run of synchronous mutations before the
    /// scheduled task is serviced shares one prune+write of the FINAL state.
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { [weak self] in await self?.persist() }
    }

    /// Prune then best-effort atomic write. `.atomic` writes a temp file and
    /// renames, so a crash mid-write can't leave a half-written store that fails
    /// to decode. Any failure is swallowed. Clears the coalescing flag so the
    /// NEXT mutation schedules a fresh write of whatever state exists then.
    private func persist() {
        persistScheduled = false
        prune()
        let url = storeURL
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
