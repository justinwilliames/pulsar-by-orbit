// DroneLifecycleTests.swift — standalone test harness for the AudioQueueActor
// in-flight sub-agent drone lifecycle.
//
// WHY A STANDALONE HARNESS (not `swift test` / XCTest):
// The build machine has Command Line Tools only (no full Xcode). That toolchain
// ships neither XCTest nor Swift Testing on the SwiftPM module search path, so a
// `.testTarget` fails to resolve `import XCTest`/`import Testing`. Rather than
// restructure the (Sparkle/rpath-sensitive) app build, this harness compiles the
// REAL AudioQueueActor + CaldwellConfig sources (no duplication — the tests
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
}

// MARK: - Entry point

@main
struct DroneTestMain {
    static func main() async {
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
