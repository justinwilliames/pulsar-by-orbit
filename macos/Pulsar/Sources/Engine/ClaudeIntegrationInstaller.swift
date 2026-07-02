import Foundation

/// Installs Pulsar's Claude Code voice integration — the skill, the hooks, and
/// the `say.sh` CLI it leans on — into the user's `~/.claude`, for a user who
/// downloaded only the DMG and has neither the repo nor a shell script to run.
///
/// Everything ships inside the app bundle (Contents/Resources/claude-integration,
/// populated by build-pulsar-app.sh). This type copies those files into a
/// stable location under `~/.claude/skills/pulsar/` and wires the hooks into
/// `~/.claude/settings.json`, mirroring the manual `scripts/install-hooks.sh`.
///
/// SAFETY IS PARAMOUNT — this edits the user's Claude config:
///   • The settings.json is BACKED UP (timestamped) before any write.
///   • The JSON is parsed and validated BEFORE and AFTER editing.
///   • Edits are IDEMPOTENT: an existing Pulsar hook is updated in place, never
///     duplicated, and no other hook or top-level key is ever touched.
///   • The write is ATOMIC (temp file in the same dir, then rename).
///   • Any failure aborts cleanly with a clear message and leaves the original
///     settings.json untouched.
struct ClaudeIntegrationInstaller {

    // MARK: - Result types

    struct InstallResult {
        let skillPath: String
        let scriptsPath: String
        let settingsPath: String
        let backupPath: String?
        /// Human-readable per-hook outcome, e.g. "Stop (voice): added".
        let hookOutcomes: [String]
    }

    struct UninstallResult {
        let settingsPath: String
        let backupPath: String?
        let skillRemoved: Bool
        /// Human-readable per-hook outcome, e.g. "Stop (voice): removed".
        let hookOutcomes: [String]
    }

    enum InstallError: LocalizedError {
        case claudeNotFound(String)
        case bundlePayloadMissing(String)
        case fileCopyFailed(String)
        case settingsUnreadable(String)
        case settingsInvalidJSON(String)
        case settingsWriteFailed(String)
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound(let m),
                 .bundlePayloadMissing(let m),
                 .fileCopyFailed(let m),
                 .settingsUnreadable(let m),
                 .settingsInvalidJSON(let m),
                 .settingsWriteFailed(let m),
                 .validationFailed(let m):
                return m
            }
        }
    }

    // MARK: - Configuration

    /// The base `.claude` directory. Defaults to `~/.claude`; tests override it
    /// to a throwaway temp dir so the real config is never touched.
    let claudeDir: URL

    /// Where the bundled payload lives. Defaults to
    /// `Bundle.main.resourceURL/claude-integration`; tests point it at a fixture.
    let payloadDir: URL?

    init(claudeDir: URL? = nil, payloadDir: URL? = nil) {
        self.claudeDir = claudeDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        self.payloadDir = payloadDir
            ?? Bundle.main.resourceURL?
                .appendingPathComponent("claude-integration", isDirectory: true)
    }

    // Files that make up the payload. Kept in lockstep with
    // build-pulsar-app.sh's sync list.
    private static let scriptNames = [
        "say.sh", "session-start-voice.sh", "stop-hook.sh",
        "chime.sh", "turn-start.sh", "statusline.sh",
        "subagent-start.sh", "subagent-stop.sh",
        // Shipped so a user who wants to reverse the wiring by hand has the
        // script locally (the in-app "Remove Pulsar" button is the primary path).
        "uninstall-hooks.sh",
    ]
    private static let rootFiles = ["SKILL.md", "CANON.md", "voices.json"]

    // MARK: - Public entry

    @discardableResult
    func install() throws -> InstallResult {
        let fm = FileManager.default

        // (a) Claude Code must be present. We treat an existing ~/.claude as the
        //     signal. If it's absent, we do NOTHING and tell the user.
        guard fm.fileExists(atPath: claudeDir.path) else {
            throw InstallError.claudeNotFound(
                "Claude Code not found — install it first, then retry. "
                + "(Looked for \(claudeDir.path).)")
        }

        // The bundled payload must exist or there is nothing to install.
        guard let payloadDir, fm.fileExists(atPath: payloadDir.path) else {
            throw InstallError.bundlePayloadMissing(
                "Pulsar's Claude integration files are missing from the app bundle. "
                + "Reinstall Pulsar and try again.")
        }

        let skillDir = claudeDir
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("pulsar", isDirectory: true)
        let scriptsDir = skillDir.appendingPathComponent("scripts", isDirectory: true)

        // (b) + (c) Copy the skill + supporting files + scripts into place.
        try copyPayload(from: payloadDir, skillDir: skillDir, scriptsDir: scriptsDir)

        // (d) Wire the hooks into settings.json — backed up, idempotent, atomic.
        let settingsPath = claudeDir.appendingPathComponent("settings.json")
        let wiring = try wireHooks(settingsPath: settingsPath, scriptsDir: scriptsDir)

        return InstallResult(
            skillPath: skillDir.path,
            scriptsPath: scriptsDir.path,
            settingsPath: settingsPath.path,
            backupPath: wiring.backupPath,
            hookOutcomes: wiring.outcomes)
    }

    /// Symmetric inverse of `install()`. Reuses the same timestamped-backup +
    /// validate + atomic-write machinery. Removes ONLY Pulsar-owned entries:
    ///   • the six managed hooks (matched by the installed
    ///     `skills/pulsar/scripts/<name>` path suffix — same ownership check the
    ///     installer uses), leaving every other user hook intact;
    ///   • the `statusLine` IF it points at Pulsar's installed statusline.sh;
    ///   • the `~/.claude/skills/pulsar` payload dir (best-effort).
    /// Never touches a foreign hook, a custom statusLine, or any other top-level
    /// key. Safe to run when nothing is installed (all outcomes "not present").
    @discardableResult
    func uninstall() throws -> UninstallResult {
        let fm = FileManager.default

        guard fm.fileExists(atPath: claudeDir.path) else {
            throw InstallError.claudeNotFound(
                "Claude Code not found — nothing to remove. "
                + "(Looked for \(claudeDir.path).)")
        }

        let skillDir = claudeDir
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("pulsar", isDirectory: true)

        let settingsPath = claudeDir.appendingPathComponent("settings.json")
        let wiring = try unwireHooks(settingsPath: settingsPath)

        // Remove the installed payload dir (best-effort, non-fatal).
        var skillRemoved = false
        if fm.fileExists(atPath: skillDir.path) {
            do {
                try fm.removeItem(at: skillDir)
                skillRemoved = true
            } catch {
                skillRemoved = false   // leave it; hooks are already unwired
            }
        }

        return UninstallResult(
            settingsPath: settingsPath.path,
            backupPath: wiring.backupPath,
            skillRemoved: skillRemoved,
            hookOutcomes: wiring.outcomes)
    }

    // MARK: - File copy

    private func copyPayload(from payloadDir: URL, skillDir: URL, scriptsDir: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

            // Skill + CANON.md + voices.json sit at the skill root. say.sh resolves
            // REPO_ROOT as scripts/.., i.e. the skill root, where it looks for an
            // optional .env (absent → harmless) and where CANON/voices live for
            // parity with the repo layout.
            for name in Self.rootFiles {
                try copyReplacing(payloadDir.appendingPathComponent(name),
                                  to: skillDir.appendingPathComponent(name))
            }

            // Scripts → skills/pulsar/scripts/, made executable. The hooks compute
            // SAY="$SCRIPT_DIR/say.sh", so co-locating all scripts keeps every
            // relative path resolving against the installed dir, never ~/code/...
            let execPerms: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
            for name in Self.scriptNames {
                let dest = scriptsDir.appendingPathComponent(name)
                try copyReplacing(payloadDir.appendingPathComponent("scripts").appendingPathComponent(name),
                                  to: dest)
                try fm.setAttributes(execPerms, ofItemAtPath: dest.path)
            }
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.fileCopyFailed(
                "Couldn't copy Pulsar's integration files into \(skillDir.path): "
                + error.localizedDescription)
        }
    }

    private func copyReplacing(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            throw InstallError.bundlePayloadMissing(
                "Missing bundled file: \(src.lastPathComponent)")
        }
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: src, to: dest)
    }

    // MARK: - Hook wiring

    private struct WiringResult {
        let backupPath: String?
        let outcomes: [String]
    }

    /// The hook entries Pulsar manages, mirroring scripts/install-hooks.sh.
    private struct ManagedHook {
        let event: String          // SessionStart / Stop / UserPromptSubmit
        let scriptName: String     // file under scripts/
        let label: String          // for the outcome string
        let timeout: Int
    }

    private let managedHooks: [ManagedHook] = [
        .init(event: "Stop", scriptName: "stop-hook.sh", label: "Stop (voice)", timeout: 5),
        .init(event: "Stop", scriptName: "chime.sh", label: "Stop (chime)", timeout: 5),
        .init(event: "SessionStart", scriptName: "session-start-voice.sh", label: "SessionStart", timeout: 5),
        .init(event: "UserPromptSubmit", scriptName: "turn-start.sh", label: "UserPromptSubmit", timeout: 5),
        .init(event: "SubagentStart", scriptName: "subagent-start.sh", label: "SubagentStart (drones)", timeout: 5),
        .init(event: "SubagentStop", scriptName: "subagent-stop.sh", label: "SubagentStop (drones)", timeout: 5),
    ]

    private func wireHooks(settingsPath: URL, scriptsDir: URL) throws -> WiringResult {
        let fm = FileManager.default

        // Load existing settings, or start a minimal valid object if absent.
        var root: [String: Any]
        var backupPath: String? = nil

        if fm.fileExists(atPath: settingsPath.path) {
            let data: Data
            do {
                data = try Data(contentsOf: settingsPath)
            } catch {
                throw InstallError.settingsUnreadable(
                    "Couldn't read \(settingsPath.path): \(error.localizedDescription)")
            }
            // Validate BEFORE editing.
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw InstallError.settingsInvalidJSON(
                    "\(settingsPath.lastPathComponent) is not valid JSON, so Pulsar won't touch it. "
                    + "Fix or remove it, then retry. (\(error.localizedDescription))")
            }
            guard let obj = parsed as? [String: Any] else {
                throw InstallError.settingsInvalidJSON(
                    "\(settingsPath.lastPathComponent) isn't a JSON object — Pulsar won't touch it.")
            }
            root = obj

            // Back it up (timestamped) before any write.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = settingsPath
                .deletingLastPathComponent()
                .appendingPathComponent("settings.json.pulsar-bak.\(stamp)")
            do {
                if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                try fm.copyItem(at: settingsPath, to: backup)
                backupPath = backup.path
            } catch {
                throw InstallError.settingsWriteFailed(
                    "Couldn't back up settings.json before editing — aborting to be safe. "
                    + "(\(error.localizedDescription))")
            }
        } else {
            try? fm.createDirectory(at: settingsPath.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            root = [:]
        }

        // Mutate a working copy.
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var outcomes: [String] = []

        for managed in managedHooks {
            let command = scriptsDir.appendingPathComponent(managed.scriptName).path
            let outcome = upsertHook(into: &hooks,
                                     event: managed.event,
                                     command: command,
                                     scriptName: managed.scriptName,
                                     timeout: managed.timeout)
            outcomes.append("\(managed.label): \(outcome)")
        }
        root["hooks"] = hooks

        // statusLine is a top-level object, not a hook. Only set it if absent or
        // if it already points at a Pulsar statusline.sh — never clobber a custom
        // status line the user configured.
        let statuslineCmd = scriptsDir.appendingPathComponent("statusline.sh").path
        if let sl = root["statusLine"] as? [String: Any],
           let existing = sl["command"] as? String {
            // Only treat it as Pulsar-owned if it's our installed statusline path.
            // A loose "*statusline.sh" suffix would wrongly claim a user's
            // "my-custom-statusline.sh", so we match the full installed suffix.
            if existing.hasSuffix("skills/pulsar/scripts/statusline.sh") {
                if existing != statuslineCmd {
                    var updated = sl
                    updated["command"] = statuslineCmd
                    root["statusLine"] = updated
                    outcomes.append("statusLine: updated")
                } else {
                    outcomes.append("statusLine: already present")
                }
            } else {
                outcomes.append("statusLine: left as-is (custom status line present)")
            }
        } else if root["statusLine"] == nil {
            root["statusLine"] = [
                "type": "command",
                "command": statuslineCmd,
                "refreshInterval": 30,
                "padding": 0,
            ]
            outcomes.append("statusLine: added")
        } else {
            // Present but not a recognizable object — don't touch it.
            outcomes.append("statusLine: left as-is")
        }

        // Serialize. Validate the serialized bytes re-parse BEFORE writing.
        let outData: Data
        do {
            outData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw InstallError.settingsWriteFailed(
                "Couldn't serialize the updated settings.json: \(error.localizedDescription)")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: outData)
        } catch {
            throw InstallError.validationFailed(
                "Internal error: produced invalid JSON. Your settings.json was NOT modified"
                + (backupPath.map { " (backup at \($0))" } ?? "") + ".")
        }

        // Atomic write: temp file in the same directory, then rename over.
        let tmp = settingsPath.deletingLastPathComponent()
            .appendingPathComponent(".settings.json.pulsar-tmp.\(UUID().uuidString)")
        do {
            try outData.write(to: tmp, options: .atomic)
            _ = try fm.replaceItemAt(settingsPath, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw InstallError.settingsWriteFailed(
                "Couldn't write settings.json: \(error.localizedDescription). "
                + "Your original is unchanged"
                + (backupPath.map { " (backup at \($0))" } ?? "") + ".")
        }

        // Validate AFTER: the file on disk must parse.
        do {
            let check = try Data(contentsOf: settingsPath)
            _ = try JSONSerialization.jsonObject(with: check)
        } catch {
            throw InstallError.validationFailed(
                "settings.json failed its post-write validation. "
                + (backupPath.map { "Restore from \($0) if needed." } ?? ""))
        }

        return WiringResult(backupPath: backupPath, outcomes: outcomes)
    }

    /// Inverse of `wireHooks`: strip every Pulsar-owned hook + statusLine from an
    /// existing settings.json, reusing the same backup / validate / atomic-write
    /// path. If settings.json is absent there is nothing to remove — returns a
    /// clean "not present" result without creating a file.
    private func unwireHooks(settingsPath: URL) throws -> WiringResult {
        let fm = FileManager.default

        guard fm.fileExists(atPath: settingsPath.path) else {
            return WiringResult(backupPath: nil,
                                outcomes: ["settings.json: not present — nothing to remove"])
        }

        let data: Data
        do {
            data = try Data(contentsOf: settingsPath)
        } catch {
            throw InstallError.settingsUnreadable(
                "Couldn't read \(settingsPath.path): \(error.localizedDescription)")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw InstallError.settingsInvalidJSON(
                "\(settingsPath.lastPathComponent) is not valid JSON, so Pulsar won't touch it. "
                + "Fix or remove it, then retry. (\(error.localizedDescription))")
        }
        guard var root = parsed as? [String: Any] else {
            throw InstallError.settingsInvalidJSON(
                "\(settingsPath.lastPathComponent) isn't a JSON object — Pulsar won't touch it.")
        }

        // Back up before any write (timestamped), same as install.
        var backupPath: String? = nil
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = settingsPath
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json.pulsar-bak.\(stamp)")
        do {
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.copyItem(at: settingsPath, to: backup)
            backupPath = backup.path
        } catch {
            throw InstallError.settingsWriteFailed(
                "Couldn't back up settings.json before editing — aborting to be safe. "
                + "(\(error.localizedDescription))")
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var outcomes: [String] = []

        for managed in managedHooks {
            let outcome = removeHook(from: &hooks,
                                     event: managed.event,
                                     scriptName: managed.scriptName)
            outcomes.append("\(managed.label): \(outcome)")
        }
        // Prune the hooks object entirely if we emptied it, to keep settings tidy.
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        // statusLine: remove ONLY if it's Pulsar's installed statusline.sh.
        if let sl = root["statusLine"] as? [String: Any],
           let existing = sl["command"] as? String,
           existing.hasSuffix("skills/pulsar/scripts/statusline.sh") {
            root.removeValue(forKey: "statusLine")
            outcomes.append("statusLine: removed")
        } else if root["statusLine"] != nil {
            outcomes.append("statusLine: left as-is (not Pulsar's)")
        } else {
            outcomes.append("statusLine: not present")
        }

        // Serialize + validate + atomic-write, identical to install.
        let outData: Data
        do {
            outData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw InstallError.settingsWriteFailed(
                "Couldn't serialize the updated settings.json: \(error.localizedDescription)")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: outData)
        } catch {
            throw InstallError.validationFailed(
                "Internal error: produced invalid JSON. Your settings.json was NOT modified"
                + (backupPath.map { " (backup at \($0))" } ?? "") + ".")
        }

        let tmp = settingsPath.deletingLastPathComponent()
            .appendingPathComponent(".settings.json.pulsar-tmp.\(UUID().uuidString)")
        do {
            try outData.write(to: tmp, options: .atomic)
            _ = try fm.replaceItemAt(settingsPath, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw InstallError.settingsWriteFailed(
                "Couldn't write settings.json: \(error.localizedDescription). "
                + "Your original is unchanged"
                + (backupPath.map { " (backup at \($0))" } ?? "") + ".")
        }

        do {
            let check = try Data(contentsOf: settingsPath)
            _ = try JSONSerialization.jsonObject(with: check)
        } catch {
            throw InstallError.validationFailed(
                "settings.json failed its post-write validation. "
                + (backupPath.map { "Restore from \($0) if needed." } ?? ""))
        }

        return WiringResult(backupPath: backupPath, outcomes: outcomes)
    }

    /// Remove the Pulsar-owned hook for `scriptName` from an event array, matched
    /// by the installed path suffix (same ownership test as `upsertHook`). Prunes
    /// emptied hook-groups and the emptied event key so no dangling shells remain.
    /// Foreign hooks in the same group/event are untouched.
    /// Returns "removed" | "not present".
    private func removeHook(from hooks: inout [String: Any],
                            event: String,
                            scriptName: String) -> String {
        let suffix = "skills/pulsar/scripts/\(scriptName)"

        guard var groups = hooks[event] as? [[String: Any]] else { return "not present" }

        var removedAny = false
        for gi in groups.indices {
            guard var inner = groups[gi]["hooks"] as? [[String: Any]] else { continue }
            let before = inner.count
            inner.removeAll { entry in
                (entry["command"] as? String)?.hasSuffix(suffix) == true
            }
            if inner.count != before {
                removedAny = true
                groups[gi]["hooks"] = inner
            }
        }

        // Drop any group whose hooks array is now empty (and had no other keys of
        // value). Keep groups that still carry hooks.
        groups.removeAll { group in
            (group["hooks"] as? [[String: Any]])?.isEmpty ?? false
        }

        if groups.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = groups
        }

        return removedAny ? "removed" : "not present"
    }

    /// Add or update a single Pulsar hook in an event array. Idempotent: an
    /// existing Pulsar hook for the same script (matched by the installed path
    /// suffix) is updated in place; no duplicate is appended; OTHER hooks in the
    /// same event are never touched. Returns "added" | "updated" | "already present".
    private func upsertHook(into hooks: inout [String: Any],
                            event: String,
                            command: String,
                            scriptName: String,
                            timeout: Int) -> String {
        // The installed-path suffix is what identifies a Pulsar-owned hook even
        // if an older install used a slightly different absolute prefix.
        let suffix = "skills/pulsar/scripts/\(scriptName)"

        var groups = (hooks[event] as? [[String: Any]]) ?? []

        for gi in groups.indices {
            guard var inner = groups[gi]["hooks"] as? [[String: Any]] else { continue }
            for hi in inner.indices {
                guard let cmd = inner[hi]["command"] as? String else { continue }
                if cmd.hasSuffix(suffix) {
                    // Found a Pulsar hook for this script. Update in place.
                    if cmd == command && (inner[hi]["timeout"] as? Int) == timeout {
                        return "already present"
                    }
                    inner[hi]["command"] = command
                    inner[hi]["timeout"] = timeout
                    inner[hi]["type"] = "command"
                    groups[gi]["hooks"] = inner
                    hooks[event] = groups
                    return "updated"
                }
            }
        }

        // Not present anywhere — append a fresh group, leaving others intact.
        let newGroup: [String: Any] = [
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": timeout,
            ]],
        ]
        groups.append(newGroup)
        hooks[event] = groups
        return "added"
    }
}
