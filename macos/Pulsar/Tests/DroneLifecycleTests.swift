// DroneLifecycleTests.swift — standalone test harness for the AudioQueueActor
// in-flight sub-agent drone lifecycle.
//
// WHY A STANDALONE HARNESS (not `swift test` / XCTest):
// The build machine has Command Line Tools only (no full Xcode). That toolchain
// ships neither XCTest nor Swift Testing on the SwiftPM module search path, so a
// `.testTarget` fails to resolve `import XCTest`/`import Testing`. Rather than
// restructure the (Sparkle/rpath-sensitive) app build, this harness compiles the
// REAL AudioQueueActor + PulsarConfig sources (no duplication — the tests
// exercise the shipping code) together with a tiny built-in assert framework and
// runs as a plain executable. See scripts/run-tests.sh for the swiftc call.
//
// NativeVoiceClient is stubbed below rather than compiled: the actor references
// it ONLY from its audio-playback path (speakNative), which these lifecycle
// tests never invoke, and the real NativeVoiceClient drags in DroneRegistry +
// the SwiftUI colour stack. The stub satisfies the compiler with zero
// behavioural impact on the drone-lifecycle logic under test.
//
// It drives the actor directly via its internal test seams — no audio worker, no
// `afplay`, no live daemon — and points the drone store at a per-test temp file
// via `setDronesStoreOverride`, so the real repo-cache `cache/drones.json` and
// the running app are never touched.

import Foundation

// MARK: - Stub for the audio-only NativeVoiceClient dependency (see header note)

enum NativeVoiceClient {
    static let defaultRate = 168
    static func bestVoice() -> String { "Daniel" }
}

// MARK: - Minimal assertion harness

actor TestReport {
    private(set) var passed = 0
    private(set) var failed = 0
    private var failures: [String] = []

    func ok(_ cond: Bool, _ msg: String) {
        if cond { passed += 1 }
        else { failed += 1; failures.append(msg); print("  ✘ \(msg)") }
    }

    func summary() -> (Int, Int, [String]) { (passed, failed, failures) }
}

let report = TestReport()

func expect(_ cond: Bool, _ msg: String) async { await report.ok(cond, msg) }

/// Run a named test closure, printing its heading.
func test(_ name: String, _ body: () async -> Void) async {
    print("• \(name)")
    await body()
}

// MARK: - Fixtures

func makeActor() async -> (AudioQueueActor, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("drone-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = dir.appendingPathComponent("drones.json")
    let actor = AudioQueueActor()
    await actor.setDronesStoreOverride(store)
    return (actor, store)
}

/// Hand-write a drones.json with one drone at an explicit lastSeen, so restore
/// gives that drone a deterministic (e.g. ancient) timestamp.
func writeStore(_ url: URL, id: String, category: String, lastSeen: Date) {
    let payload: [String: [String: Any]] = [
        id: ["category": category, "lastSeen": lastSeen.timeIntervalSince1970],
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    try! data.write(to: url)
}

// MARK: - Tests

func runAll() async {
    // 1. add then remove while NOT speaking → removed immediately
    await test("removeWhileNotSpeaking → removes immediately") {
        let (actor, _) = await makeActor()
        await actor.addInFlightDrone(id: "a1", category: "voyager")
        await expect(await actor.inFlightDronesSnapshot()["a1"] == "voyager", "added drone present")
        let removedNow = await actor.removeInFlightDrone(id: "a1")
        await expect(removedNow, "not speaking → removal returns true")
        await expect(await actor.inFlightDronesSnapshot()["a1"] == nil, "drone gone")
        await expect(await actor._test_isPending(id: "a1") == false, "not left pending")
    }

    // 2. remove while its category IS speaking → deferred, then flushed
    await test("removeWhileSpeaking → deferred, then flushed") {
        let (actor, _) = await makeActor()
        await actor.addInFlightDrone(id: "a1", category: "voyager")
        await actor._test_setSpeakingCategory("voyager")
        let removedNow = await actor.removeInFlightDrone(id: "a1")
        await expect(removedNow == false, "speaking → deferred, returns false")
        await expect(await actor.inFlightDronesSnapshot()["a1"] == "voyager", "stays while speaking")
        await expect(await actor._test_isPending(id: "a1"), "marked pending")
        await actor._test_setSpeakingCategory(nil)
        let flushed = await actor.flushDeferredRemovals()
        await expect(flushed != nil, "flush returns snapshot when it removes")
        await expect(await actor.inFlightDronesSnapshot()["a1"] == nil, "removed once speech ended")
    }

    // 2b. deferral holds while a same-category line is still QUEUED
    await test("flush holds while same-category line still queued") {
        let (actor, _) = await makeActor()
        await actor.addInFlightDrone(id: "a1", category: "voyager")
        await actor._test_setSpeakingCategory("voyager")
        _ = await actor.removeInFlightDrone(id: "a1")
        await actor._test_setSpeakingCategory(nil)
        await actor._test_appendQueuedCategory("voyager")
        let flushedEarly = await actor.flushDeferredRemovals()
        await expect(flushedEarly == nil, "same-category still queued → deferral holds")
        await expect(await actor.inFlightDronesSnapshot()["a1"] == "voyager", "drone retained")
    }

    // 3. sweepStaleDrones with injected clock
    await test("sweepStaleDrones evicts stale, keeps fresh") {
        let (actor, store) = await makeActor()
        let ancient = Date().addingTimeInterval(-(AudioQueueActor.droneStaleAfter + 300))
        writeStore(store, id: "old", category: "voyager", lastSeen: ancient)
        await actor.restoreInFlight()
        await actor.addInFlightDrone(id: "fresh", category: "sentinel")
        let swept = await actor.sweepStaleDrones(now: Date())
        await expect(swept != nil, "stale drone evicted → broadcast")
        let snap = await actor.inFlightDronesSnapshot()
        await expect(snap["old"] == nil, "stale drone evicted")
        await expect(snap["fresh"] == "sentinel", "fresh drone survives")
    }

    await test("sweep with nothing stale → nil (no broadcast)") {
        let (actor, _) = await makeActor()
        await actor.addInFlightDrone(id: "a1", category: "voyager")
        await expect(await actor.sweepStaleDrones(now: Date()) == nil, "fresh → no eviction")
    }

    // 4. restoreInFlight round-trip — category + lastSeen preserved (promoted stays)
    await test("restore round-trip preserves category + lastSeen") {
        let (actor, store) = await makeActor()
        await actor.addInFlightDrone(id: "p1", category: "atlas")
        _ = await actor.promoteInFlightDrone(toCategory: "nebula")
        await actor.addInFlightDrone(id: "p2", category: "echo")
        let beforeSeen = await actor._test_lastSeen(id: "p2")
        await expect(beforeSeen != nil, "p2 has lastSeen")
        await actor.flushPersistForTests()

        let restored = AudioQueueActor()
        await restored.setDronesStoreOverride(store)
        await restored.restoreInFlight()
        let snap = await restored.inFlightDronesSnapshot()
        await expect(snap["p1"] == "nebula", "promoted category restored, NOT reverted to atlas")
        await expect(snap["p2"] == "echo", "plain category restored")
        let afterSeen = await restored._test_lastSeen(id: "p2")
        let delta = abs((afterSeen?.timeIntervalSince1970 ?? -1) - (beforeSeen?.timeIntervalSince1970 ?? 0))
        await expect(afterSeen != nil && delta < 0.001, "lastSeen preserved through round-trip")
    }

    // 5. promote — generic promoted; already-labelled is a no-op; empty/pulsar never
    await test("promote: generic promoted, labelled is a no-op") {
        let (actor, _) = await makeActor()
        await actor.addInFlightDrone(id: "g1", category: "atlas")
        let promoted = await actor.promoteInFlightDrone(toCategory: "nova")
        await expect(promoted, "generic atlas promoted → true")
        await expect(await actor.inFlightDronesSnapshot()["g1"] == "nova", "g1 now nova")
        let again = await actor.promoteInFlightDrone(toCategory: "nova")
        await expect(again == false, "already present → no-op false")
        let novaCount = await actor.inFlightDronesSnapshot().values.filter { $0 == "nova" }.count
        await expect(novaCount == 1, "no duplicate nova")
        await expect(await actor.promoteInFlightDrone(toCategory: "") == false, "empty never promotes")
        await expect(await actor.promoteInFlightDrone(toCategory: "pulsar") == false, "pulsar never promotes")
    }

    await test("promote prefers same-session generic") {
        let (actor, _) = await makeActor()
        await actor.addInFlightDrone(id: "genA", category: "atlas", sessionId: "A")
        await actor.addInFlightDrone(id: "genB", category: "atlas", sessionId: "B")
        let promoted = await actor.promoteInFlightDrone(toCategory: "echo", sessionId: "B")
        await expect(promoted, "promoted within session B")
        let snap = await actor.inFlightDronesSnapshot()
        await expect(snap["genB"] == "echo", "same-session generic claimed")
        await expect(snap["genA"] == "atlas", "other session's generic untouched")
    }

    // 6. Regression guard — re-register clears pendingRemoval
    await test("re-registration clears pendingRemoval (not evicted by flush)") {
        let (actor, _) = await makeActor()
        await actor.addInFlightDrone(id: "a1", category: "voyager")
        await actor._test_setSpeakingCategory("voyager")
        _ = await actor.removeInFlightDrone(id: "a1")
        await expect(await actor._test_isPending(id: "a1"), "deferred → pending")
        await actor.addInFlightDrone(id: "a1", category: "voyager")   // re-register
        await expect(await actor._test_isPending(id: "a1") == false, "re-register clears pending")
        await actor._test_setSpeakingCategory(nil)
        let flushed = await actor.flushDeferredRemovals()
        await expect(flushed == nil, "nothing pending → flush removes nothing")
        await expect(await actor.inFlightDronesSnapshot()["a1"] == "voyager", "re-registered drone survives")
    }

    await test("re-registration does not demote a promoted label") {
        let (actor, _) = await makeActor()
        await actor.addInFlightDrone(id: "d1", category: "atlas")
        _ = await actor.promoteInFlightDrone(toCategory: "nova")
        await expect(await actor.inFlightDronesSnapshot()["d1"] == "nova", "promoted to nova")
        await actor.addInFlightDrone(id: "d1", category: "atlas")   // generic re-start
        await expect(await actor.inFlightDronesSnapshot()["d1"] == "nova", "generic re-start doesn't demote")
    }

    // 7. Idempotent removal — removing an absent id returns false
    await test("removing an absent id returns false") {
        let (actor, _) = await makeActor()
        let removed = await actor.removeInFlightDrone(id: "ghost")
        await expect(removed == false, "absent id → not removed")
    }

    // sweep idempotence — second sweep of same state does not re-broadcast
    await test("second sweep of same state returns nil") {
        let (actor, store) = await makeActor()
        let ancient = Date().addingTimeInterval(-(AudioQueueActor.droneStaleAfter + 300))
        writeStore(store, id: "old", category: "voyager", lastSeen: ancient)
        await actor.restoreInFlight()
        await expect(await actor.sweepStaleDrones(now: Date()) != nil, "first sweep evicts")
        await expect(await actor.sweepStaleDrones(now: Date()) == nil, "second sweep → nil")
    }

    // MARK: - Mute: immediate silence (BUG 2)
    //
    // `muteNow` is the actor half of the immediate-mute path: kill the current
    // playback (no live process in a test, so that's a no-op) AND drop every
    // still-queued waiter so nothing sounds while muted. We seed the queue via the
    // same `_test_appendQueuedCategory` seam the deferral tests use (appends
    // without starting the real afplay worker) and assert the queue is emptied.

    await test("muteNow drops all queued lines (immediate silence)") {
        let (actor, _) = await makeActor()
        await actor._test_appendQueuedCategory("voyager")
        await actor._test_appendQueuedCategory("nova")
        await actor._test_appendQueuedCategory("echo")
        await expect(await actor._test_queueDepth() == 3, "three lines queued")
        await actor.muteNow()
        await expect(await actor._test_queueDepth() == 0, "muteNow cleared the queue")
    }

    await test("muteNow on an empty queue is a safe no-op") {
        let (actor, _) = await makeActor()
        await expect(await actor._test_queueDepth() == 0, "starts empty")
        await actor.muteNow()  // must not crash / underflow
        await expect(await actor._test_queueDepth() == 0, "still empty, no throw")
    }

    // MARK: - PulsarConfig: Fix 2 (set() preserves siblings) + Fix 3 (migration)
    //
    // These drive the SHARED PulsarConfig.shared singleton. Its storageRoot reads
    // PULSAR_STORAGE from the env at every access, so each test points it at a
    // fresh temp dir via `setenv` before writing/reading. All assertions read the
    // config.json bytes back directly, so they don't depend on the singleton's
    // in-memory _config (loaded once at process init against whatever env was set
    // first — see the entry point, which seeds a throwaway dir before anything
    // touches the singleton).

    // Default native voice (BUG 1): out-of-box, no PULSAR_NATIVE_VOICE is set, so
    // `nativeVoiceChoice` is empty → the resolver falls through to the BASE name
    // (Daniel), never an Enhanced/Premium variant a stock Mac lacks. This asserts
    // the config precondition that keeps the default a base voice; the resolver
    // itself (NativeVoiceClient, AVFoundation-backed) can't run in this harness.
    await test("default native voice is unset → base (BUG 1)") {
        let cfg = PulsarConfig.shared
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-voice-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("PULSAR_STORAGE", dir.path, 1)
        unsetenv("PULSAR_NATIVE_VOICE")  // no env override either

        // A fresh config with NO voice key — the stock out-of-box shape.
        let seed: [String: Any] = ["PULSAR_MUTED": "0"]
        try! JSONSerialization.data(withJSONObject: seed).write(to: cfg.configPath)
        cfg.reload()

        await expect(cfg.nativeVoiceChoice.isEmpty,
                     "no explicit choice → empty (resolver uses base Daniel, not Enhanced)")

        // An EXPLICIT opt-in is preserved verbatim (honoured only if installed at
        // speak time — checked in NativeVoiceClient.resolvedRespectingChoice).
        try! cfg.set("PULSAR_NATIVE_VOICE", value: "Daniel (Enhanced)")
        cfg.reload()
        await expect(cfg.nativeVoiceChoice == "Daniel (Enhanced)",
                     "explicit Enhanced opt-in is retained")

        unsetenv("PULSAR_STORAGE")
    }

    await test("set() preserves a Bool-valued sibling key (Fix 2)") {
        let cfg = PulsarConfig.shared
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-set-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("PULSAR_STORAGE", dir.path, 1)

        // A config whose sibling holds a real JSON Bool (not a string) — the exact
        // shape the old strict `as? [String: String]` cast returned nil on, then
        // clobbered on the next write.
        let seed: [String: Any] = ["PULSAR_MUTED": true, "PULSAR_NATIVE_VOICE": "Trinoids"]
        let seedData = try! JSONSerialization.data(withJSONObject: seed)
        try! seedData.write(to: cfg.configPath)

        try! cfg.set("PULSAR_EXPLETIVES", value: "1")

        let after = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: cfg.configPath)) as! [String: Any]
        await expect(after["PULSAR_EXPLETIVES"] as? String == "1", "new key written")
        // The Bool sibling must survive (coerced to "1"), NOT be wiped.
        let mutedSurvived = after["PULSAR_MUTED"] != nil
        await expect(mutedSurvived, "Bool sibling PULSAR_MUTED preserved (not wiped)")
        await expect(after["PULSAR_NATIVE_VOICE"] as? String == "Trinoids",
                     "string sibling preserved")

        unsetenv("PULSAR_STORAGE")
    }

    // MARK: - SessionRegistry: Session Signature (new fields + rename precedence)
    //
    // These drive the REAL SessionRegistry actor against a per-test temp store,
    // so the live sessions.json and the running app are never touched.

    func makeRegistry() -> (SessionRegistry, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("sessions.json")
        return (SessionRegistry(storeOverrideURL: store), store)
    }

    // An OLD on-disk store (none of the Session Signature fields) must still
    // decode + render — graceful fallback to today's label, no crash.
    await test("old store without new fields decodes cleanly") {
        let (_, store) = makeRegistry()
        // Hand-write a record with ONLY the pre-Signature keys.
        let legacy: [String: [String: Any]] = [
            "s1": [
                "sessionId": "s1", "label": "claude",
                "lastSeen": Date().timeIntervalSinceReferenceDate,
                "phase": "waiting", "dismissed": false,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: legacy)
        try! data.write(to: store)

        let reg = SessionRegistry(storeOverrideURL: store)
        let active = await reg.activeSessions(liveSessionIds: ["s1"])
        await expect(active.count == 1, "legacy record decoded (no crash)")
        let r = active.first
        await expect(r?.branch == nil && r?.repo == nil, "new fields default to nil")
        await expect(r?.lastAction == nil && r?.userNamed == nil, "action/userNamed default nil")
        await expect(r?.label == "claude", "existing label preserved")
    }

    // A USER rename must survive a SUBSEQUENT LLM nameOverride:true call — the
    // worst regression for a trust feature would be a vanishing human title.
    await test("user rename survives a later nameOverride") {
        let (reg, _) = makeRegistry()
        await reg.note(sessionId: "s1", cwd: "/x/claude", phase: "working",
                       isUserMessage: true, name: "go")   // sticky first-message seed
        await reg.note(sessionId: "s1", cwd: nil, phase: nil,
                       name: "Auth Fix", userNamed: true) // human rename
        await reg.note(sessionId: "s1", cwd: nil, phase: nil,
                       name: "Some LLM Title", nameOverride: true)  // titler tries to clobber
        let r = await reg.activeSessions().first
        await expect(r?.name == "Auth Fix", "human title survived the LLM override")
        await expect(r?.userNamed == true, "userNamed latched")
    }

    // LIVE context (branch/repo/lastAction) always takes the freshest value; a
    // branch switch mid-session tracks.
    await test("branch/repo/lastAction take the freshest value") {
        let (reg, _) = makeRegistry()
        await reg.note(sessionId: "s1", cwd: "/x/claude", phase: "working",
                       isUserMessage: true, branch: "main", repo: "pulsar",
                       lastAction: "started")
        await reg.note(sessionId: "s1", cwd: nil, phase: nil,
                       branch: "feat/identity", lastAction: "wired the payload")
        let r = await reg.activeSessions().first
        await expect(r?.branch == "feat/identity", "branch switch tracked (freshest wins)")
        await expect(r?.repo == "pulsar", "repo retained when omitted on a later turn")
        await expect(r?.lastAction == "wired the payload", "lastAction updated")
    }

    // The LLM titler still works BEFORE any human rename (precedence unchanged
    // for the non-userNamed path).
    await test("nameOverride still replaces the seed when not user-named") {
        let (reg, _) = makeRegistry()
        await reg.note(sessionId: "s1", cwd: "/x/claude", phase: "working",
                       isUserMessage: true, name: "go")
        await reg.note(sessionId: "s1", cwd: nil, phase: nil,
                       name: "Nice Title", nameOverride: true)
        let r = await reg.activeSessions().first
        await expect(r?.name == "Nice Title", "LLM title replaced the local seed")
        await expect((r?.userNamed ?? false) == false, "userNamed stays false for an LLM title")
    }

    // MARK: - SessionIdentity: collision backstop (shortTag + non-branch monogram)
    //
    // The Session Signature's guaranteed-unique backstop. These drive the REAL
    // `SessionIdentity` derivations (the same code `MissionSession.shortTag` /
    // `.monogram` delegate to), so the view can't drift from what's tested.

    // The headline collision case: two sessions IDENTICAL on repo/branch/last-action
    // but with different ids must get DIFFERENT shortTag AND DIFFERENT monogram —
    // otherwise two live rows look the same. (Neither derivation touches branch,
    // so the shared repo/branch/action is irrelevant by construction.)
    await test("same repo/branch/action, different ids → distinct shortTag + monogram") {
        let idA = "a7f3c210-1111-4444-8888-000000000001"
        let idB = "b4e9d871-2222-5555-9999-000000000002"
        let tagA = SessionIdentity.shortTag(id: idA)
        let tagB = SessionIdentity.shortTag(id: idB)
        await expect(tagA == "#a7f3", "shortTag is #-prefixed first 4 id chars")
        await expect(tagA != tagB, "different ids → different shortTag")

        // userNamed:false → id-derived monogram (NOT branch-derived), so the
        // shared branch can't collapse them.
        let monoA = SessionIdentity.monogram(id: idA, userNamed: false, userName: nil)
        let monoB = SessionIdentity.monogram(id: idB, userNamed: false, userName: nil)
        await expect(monoA != monoB, "different ids → different monogram (not branch-collapsed)")
        await expect(monoA.count == 2 && monoB.count == 2, "id monogram is a 2-char pair")
    }

    // Non-git session (empty branch/repo — Justin's main sessions) must STILL get a
    // stable, non-blank monogram + shortTag purely from the id.
    await test("non-git session (no branch) still gets a non-blank id monogram") {
        let id = "0f1e2d3c-aaaa-bbbb-cccc-ddddeeeeffff"
        let mono = SessionIdentity.monogram(id: id, userNamed: false, userName: nil)
        await expect(!mono.isEmpty && mono.count == 2, "non-blank 2-char monogram with no branch")
        await expect(SessionIdentity.shortTag(id: id) == "#0f1e", "shortTag from id, branch-independent")
        // Determinism: same id → same derivations across calls (and processes).
        await expect(SessionIdentity.monogram(id: id, userNamed: false, userName: nil) == mono,
                     "monogram deterministic for a given id")
    }

    // A user rename drives the monogram from the PERSON'S NAME, never the id/branch.
    await test("userNamed monogram = user name initials") {
        let id = "c0ffee00-3333-6666-aaaa-111122223333"
        let mono = SessionIdentity.monogram(id: id, userNamed: true, userName: "Auth Fix")
        await expect(mono == "AF", "two-word user name → both initials, uppercased")
        let single = SessionIdentity.monogram(id: id, userNamed: true, userName: "billing")
        await expect(single == "BI", "single-word user name → first two letters")
        // A userNamed flag but an unusable (punctuation-only) name falls back to the
        // id pair rather than going blank.
        let fallback = SessionIdentity.monogram(id: id, userNamed: true, userName: "!!!")
        await expect(fallback == SessionIdentity.idPair(id), "unusable user name → id-pair fallback, never blank")
    }

    await test("migration: CALDWELL_* → PULSAR_*, PULSAR_ wins, sentinel gates (Fix 3)") {
        let cfg = PulsarConfig.shared
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-mig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("PULSAR_STORAGE", dir.path, 1)

        // A half-migrated live config exactly like the one found on disk: most
        // keys still CALDWELL_*, one already re-toggled to PULSAR_EXPLETIVES.
        let seed: [String: Any] = [
            "CALDWELL_MUTED": "0",
            "CALDWELL_NATIVE_VOICE": "Trinoids",
            "CALDWELL_EXPLETIVES": "0",   // conflicts with the PULSAR_ below
            "PULSAR_EXPLETIVES": "1",     // post-rename re-toggle — must WIN
        ]
        try! JSONSerialization.data(withJSONObject: seed).write(to: cfg.configPath)

        cfg.migrateLegacyConfigIfNeeded()

        let after = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: cfg.configPath)) as! [String: Any]
        await expect(after["PULSAR_MUTED"] as? String == "0", "CALDWELL_MUTED → PULSAR_MUTED")
        await expect(after["PULSAR_NATIVE_VOICE"] as? String == "Trinoids",
                     "CALDWELL_NATIVE_VOICE → PULSAR_NATIVE_VOICE")
        await expect(after["PULSAR_EXPLETIVES"] as? String == "1",
                     "PULSAR_ wins on conflict (kept 1, not overwritten by CALDWELL 0)")
        let noLegacy = after.keys.contains { $0.hasPrefix("CALDWELL_") } == false
        await expect(noLegacy, "all CALDWELL_* keys dropped")

        // Sentinel written on success.
        let sentinel = dir.appendingPathComponent(".migrated")
        await expect(FileManager.default.fileExists(atPath: sentinel.path),
                     "sentinel written")

        // Idempotent: re-running does nothing even if we sneak a CALDWELL_ key back.
        var tampered = after
        tampered["CALDWELL_SNEAKY"] = "x"
        try! JSONSerialization.data(withJSONObject: tampered).write(to: cfg.configPath)
        cfg.migrateLegacyConfigIfNeeded()   // sentinel present → no-op
        let after2 = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: cfg.configPath)) as! [String: Any]
        await expect(after2["CALDWELL_SNEAKY"] as? String == "x",
                     "sentinel gates re-run (sneaky key untouched, not re-migrated)")

        unsetenv("PULSAR_STORAGE")
    }

    // MARK: - MissionSession.displayTitle precedence (sidebar title tier)
    //
    // Mirrors MissionSession.displayTitle EXACTLY (that type imports SwiftUI, so
    // it isn't compiled into this Foundation-only harness — keep this replica in
    // lockstep with the real precedence ladder in
    // Sources/Models/MissionSession.swift).
    //   1. userNamed rename  >  2. sidebarTitle  >  3. name  >
    //   4. non-generic branch  >  5. label  >  6. "#"+id-prefix
    func displayTitle(id: String, name: String, label: String, branch: String,
                      userNamed: Bool, sidebarTitle: String) -> String {
        let generic: Set<String> = ["main", "master", "trunk", "develop", "dev", "head"]
        if userNamed, !name.isEmpty { return name }
        let sidebar = sidebarTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sidebar.isEmpty { return sidebar }
        if !name.isEmpty { return name }
        let b = branch.trimmingCharacters(in: .whitespaces)
        if !b.isEmpty, !generic.contains(b.lowercased()) { return b }
        if !label.isEmpty { return label }
        return "#" + String(id.prefix(4))
    }

    await test("displayTitle: sidebar wins over name/branch/label, loses to userNamed") {
        // sidebarTitle beats name (the LLM/first-message title).
        await expect(
            displayTitle(id: "a7f3b2", name: "First message here", label: "pulsar",
                         branch: "feat/x", userNamed: false,
                         sidebarTitle: "Comet, Pulsar, Orion enhancements")
                == "Comet, Pulsar, Orion enhancements",
            "sidebarTitle outranks name")

        // But a manual rename still wins over the sidebar title.
        await expect(
            displayTitle(id: "a7f3b2", name: "My Rename", label: "pulsar",
                         branch: "feat/x", userNamed: true,
                         sidebarTitle: "Sidebar Name") == "My Rename",
            "userNamed outranks sidebarTitle")

        // Empty/whitespace sidebar falls through to name.
        await expect(
            displayTitle(id: "a7f3b2", name: "The Name", label: "pulsar",
                         branch: "feat/x", userNamed: false,
                         sidebarTitle: "   ") == "The Name",
            "blank sidebarTitle falls through to name")

        // No sidebar, no name → non-generic branch; generic branch skipped.
        await expect(
            displayTitle(id: "a7f3b2", name: "", label: "pulsar",
                         branch: "feat/titles", userNamed: false,
                         sidebarTitle: "") == "feat/titles",
            "no sidebar/name → non-generic branch")
        await expect(
            displayTitle(id: "a7f3b2", name: "", label: "pulsar",
                         branch: "main", userNamed: false,
                         sidebarTitle: "") == "pulsar",
            "generic branch skipped → label")

        // Nothing set → short id tag.
        await expect(
            displayTitle(id: "a7f3b299", name: "", label: "",
                         branch: "", userNamed: false, sidebarTitle: "") == "#a7f3",
            "empty everything → #id-prefix")
    }
}

// MARK: - Entry point

@main
struct DroneTestMain {
    static func main() async {
        // Seed PULSAR_STORAGE at a throwaway dir BEFORE any code touches
        // PulsarConfig.shared, so the singleton's one-time init (and every config
        // test below) reads/writes an isolated temp config.json — never the real
        // ~/Library/Application Support/Pulsar/config.json or the running app.
        let seedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-seed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
        setenv("PULSAR_STORAGE", seedDir.path, 1)

        await runAll()
        let (passed, failed, failures) = await report.summary()
        print("\n─────────────────────────────")
        print("Drone lifecycle tests: \(passed) passed, \(failed) failed")
        if failed > 0 {
            print("FAILURES:")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
        print("ALL PASSED ✓")
        exit(0)
    }
}
