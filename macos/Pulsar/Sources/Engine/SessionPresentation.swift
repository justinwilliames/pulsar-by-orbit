import Foundation

/// Pure, Foundation-only presentation-resolution logic for the Missions board —
/// the server-side "one truth per field" layer the 2026-07-06 team review
/// mandated (R4 items 2+3). Lives in Engine so the CLT test harness can exercise
/// it (SwiftUI types can't compile there) and so the daemon — not the view —
/// owns what a row says. The view renders; it never adjudicates.
///
/// Three jobs:
///   • `isInteractive` — ADMISSION CONTROL: is this record a human session at
///     all, or a scheduled-task/routine ghost that must never count as a mission?
///   • `resolveTitle` / `cleanSidebarTitle` — ONE title, resolved where all the
///     candidate sources live, with sidebar-title date/status decoration stripped.
///   • `deriveStatus` — ONE status from the agreed 4-state machine, with
///     HEARTBEAT STALENESS (not the fragile Stop edge) as the liveness
///     authority, so a dropped Stop hook self-heals instead of latching
///     "working" for 14 days.
enum SessionPresentation {

    // MARK: - Admission control (R4 item 2)

    /// True when the record looks like a real, human-initiated session. The known
    /// ghost class: scheduled-task / cloud-routine fires whose UserPromptSubmit
    /// prompt is machine XML — their sticky first-line name starts with a
    /// `<scheduled-task`-style tag. Those fire `user_message:true` like a human,
    /// so without this gate they inflate the board count AND the 7-day window.
    /// (Temp-dir scratch sessions are already dropped hook-side; this is the
    /// daemon-side belt for legacy records and any hook that predates the guard.)
    static func isInteractive(name: String?) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return true }   // no name ≠ ghost — admit
        let lowered = name.lowercased()
        for prefix in ["<scheduled-task", "<automation", "<cloud-routine", "<cron"] {
            if lowered.hasPrefix(prefix) { return false }
        }
        return true
    }

    // MARK: - Title resolution (R4 item 3)

    /// Branches too generic to serve as a title on their own. Mirrors the view's
    /// historical list — kept here so the SERVER applies it and every client
    /// renders the same answer.
    static let genericBranches: Set<String> = ["main", "master", "trunk", "develop", "dev", "head"]

    /// Strip session-namer decoration from a Claude Desktop sidebar title:
    /// a leading "YYYY-MM-DD - " date and — only when the full convention
    /// ("date - topic - status") is present — the trailing status segment.
    /// "2026-07-03 - Skills Review And Fable Training - Discussing Improvements"
    /// → "Skills Review And Fable Training". A title that doesn't match the
    /// convention passes through untouched: this is a whitelist-shaped cleaner,
    /// never a guess.
    static func cleanSidebarTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var parts = trimmed.components(separatedBy: " - ")
        guard parts.count >= 2, isDatePrefix(parts[0]) else { return trimmed }
        parts.removeFirst()                       // drop the date
        if parts.count >= 2 { parts.removeLast() } // full convention → drop status
        let cleaned = parts.joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? trimmed : cleaned
    }

    /// "YYYY-MM-DD" check without a DateFormatter allocation.
    private static func isDatePrefix(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
        for (i, c) in chars.enumerated() where i != 4 && i != 7 {
            guard c.isNumber else { return false }
        }
        return true
    }

    /// The ONE board title, resolved server-side. Precedence (matches the view's
    /// historical contract, now applied where all the inputs live):
    ///   1. a user rename (definitive);
    ///   2. the CLEANED Claude Desktop sidebar title;
    ///   3. the sticky first-message / LLM name;
    ///   4. a non-generic branch;
    ///   5. the cwd label;
    ///   6. "#" + a short id tag.
    static func resolveTitle(
        userNamed: Bool, name: String?, sidebarTitle: String,
        branch: String?, label: String, sessionId: String
    ) -> String {
        let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if userNamed, !trimmedName.isEmpty { return trimmedName }
        let sidebar = cleanSidebarTitle(sidebarTitle)
        if !sidebar.isEmpty { return sidebar }
        if !trimmedName.isEmpty { return trimmedName }
        let b = (branch ?? "").trimmingCharacters(in: .whitespaces)
        if !b.isEmpty, !genericBranches.contains(b.lowercased()) { return b }
        if !label.isEmpty { return label }
        return "#" + String(sessionId.prefix(4))
    }

    // MARK: - Status derivation (R4 item 3 — the honest state machine)

    /// Heartbeat freshness window for "actively using a tool right now".
    static let activeWindow: TimeInterval = 30
    /// Ceiling on how long a phase=="working" session may sit with NO recent
    /// heartbeat and NO fresh user message before the board stops believing the
    /// latch and self-heals to waiting. Covers long model "thinking" gaps between
    /// tools without letting a dropped Stop lie for 14 days.
    static let workingCeiling: TimeInterval = 300

    /// The transmit-4/render-3 status per the engineering pair's state machine:
    ///   • "active"  — heartbeat within 30s (self-expiring truth);
    ///   • "working" — turn open AND recent evidence of life (heartbeat or the
    ///     user's own message within the ceiling), or drones in flight;
    ///   • "waiting" — the turn ended (Stop edge), `stale=false`;
    ///   • "waiting" + `stale=true` — the IDLE-FALLBACK: phase still says
    ///     "working" but nothing has moved within the ceiling — the self-heal for
    ///     a dropped Stop hook. Renders identically to waiting; provenance stays
    ///     auditable on the wire.
    static func deriveStatus(
        phase: String,
        lastActiveAt: Date?,
        lastUserMessage: Date?,
        hasDrones: Bool,
        now: Date = Date()
    ) -> (status: String, stale: Bool) {
        let heartbeatAge = lastActiveAt.map { now.timeIntervalSince($0) }
        if let age = heartbeatAge, age <= activeWindow { return ("active", false) }
        if hasDrones { return ("working", false) }
        guard phase == "working" else { return ("waiting", false) }
        let userAge = lastUserMessage.map { now.timeIntervalSince($0) }
        let freshest = [heartbeatAge, userAge].compactMap { $0 }.min()
        if let freshest, freshest < workingCeiling { return ("working", false) }
        return ("waiting", true)   // idle-fallback: the latch lost its authority
    }
}
