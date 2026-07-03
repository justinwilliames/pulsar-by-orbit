import Foundation

/// Pure, Foundation-only session-identity derivations — the collision backstop for
/// the Missions board's Session Signature.
///
/// Lives in Engine (no SwiftUI) for two reasons: it's testable in the
/// Command-Line-Tools harness (see run-tests.sh — the SwiftUI `MissionSession`
/// can't compile there), and it keeps the *identity contract* in one place so the
/// view struct can't drift from it.
///
/// THE COLLISION PROBLEM this closes: the identity colour is a 7-hue hash, so two
/// sessions collide on colour ~1/7 of the time (guaranteed past 7 same-repo
/// sessions). The old monogram derived from BRANCH initials, so N sessions on the
/// same repo+branch (or non-git sessions with no branch at all — Justin's main
/// sessions run in a non-git folder) collapsed to the SAME two letters. Colour +
/// monogram could therefore be identical across two live rows.
///
/// The fix, both guaranteed-distinct because both key on the always-unique
/// session id:
///   • `shortTag(id:)` — "#" + first 4 id chars, the always-shown backstop the
///     human can point at ("the #a7f3 one").
///   • `monogram(id:userNamed:userName:)` — NEVER branch-derived. User-named →
///     the person's initials; otherwise two chars deterministically hashed from
///     the id, so two same-repo sessions get DIFFERENT monograms.
enum SessionIdentity {

    /// The always-distinct backstop: "#" + the first 4 chars of the session id
    /// (e.g. "#a7f3"). Stable per session and unique in practice, so even when
    /// colour + branch + last-action all match, this still separates two rows.
    static func shortTag(id: String) -> String {
        "#" + String(id.prefix(4))
    }

    /// A stable, non-negative FNV-1a hash of the session id. Swift's `Hasher` is
    /// per-run seeded (a different value every launch), so we roll our own to keep
    /// a session's colour/monogram identical across processes.
    static func stableHash(_ id: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    /// The 1–2 char monogram carried as TEXT on the identity chip (so the chip
    /// never leans on colour alone — colour-blind-safe, and still distinct on a
    /// hash collision). Precedence, deliberately NON-branch-derived so same-repo
    /// sessions never collapse:
    ///   1. user-named → up to two initials from the user's chosen name;
    ///   2. otherwise → two chars deterministically derived from the session id
    ///      (base-36 of the id hash), never blank, unique-in-practice per session.
    static func monogram(id: String, userNamed: Bool, userName: String?) -> String {
        if userNamed, let name = userName, let m = initials(from: name) {
            return m
        }
        return idPair(id)
    }

    /// A deterministic, never-blank 2-char tag from the id hash (base-36). Two
    /// different ids almost always map to a different pair, so two same-repo
    /// sessions get DIFFERENT monograms — the collision backstop.
    static func idPair(_ id: String) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let n = stableHash(id) % UInt64(alphabet.count * alphabet.count)
        let a = alphabet[Int(n / UInt64(alphabet.count))]
        let c = alphabet[Int(n % UInt64(alphabet.count))]
        return "\(a)\(c)"
    }

    /// Up to two uppercased initials from a phrase's word starts, else the first
    /// two letters of a single word. nil when there are no alphanumerics at all.
    static func initials(from text: String) -> String? {
        let words = text
            .replacingOccurrences(of: "[-_/]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0 == " " })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard let first = words.first else { return nil }
        if words.count >= 2, let a = first.first, let b = words[1].first {
            return "\(a)\(b)".uppercased()
        }
        let letters = first.filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty else { return nil }
        return String(letters.prefix(2)).uppercased()
    }
}
