import XCTest
@testable import AislopdeskClientUI

// MARK: - ScenePhaseFanOutTests

/// Pins the iOS background/foreground **lifecycle fan-out** on ``WorkspaceStore`` (docs/22 §4, §11.4):
/// `pauseAll()` pauses EVERY materialized session and `resumeAll()` resumes EVERY session — once each,
/// across the whole canvas, including the inspector-bearing `.claudeCode` pane (whose `pause()` the
/// `LivePaneSession` routes to BOTH its connection and its inspector channel; the double records the
/// single `pause()` call, which is what the store guarantees).
///
/// The load-bearing property here is that the fan-out is **AWAITED** — the store uses a `TaskGroup`
/// that is awaited before returning, NOT fire-and-forget (a stranded `pause()` on iOS background is
/// exactly the bug the awaited group prevents: the app suspends before the socket is paused). A plain
/// counter-recording double can't distinguish "awaited" from "kicked off and forgotten" because its
/// `pause()` body finishes synchronously. So this suite also drives a *gated* double whose `pause()` /
/// `resume()` suspend on a controllable continuation, and proves that `pauseAll()` / `resumeAll()` do
/// NOT return until that continuation is released.
///
/// Everything is exercised through the `makeSession` seam with `FakePaneSession` (and a local gated
/// variant) — NEVER a `HostServer` or a connected `AislopdeskClient`.
@MainActor
final class ScenePhaseFanOutTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a store whose default workspace is one terminal pane, then grows it (via the store's own
    /// mutations, so every pane is materialized through `reconcile()`) to a multi-pane canvas that
    /// includes a `.claudeCode` pane: the default terminal + an added claudeCode + two more terminals
    /// (4 panes total on the single canvas, one of them the inspector-bearing claudeCode pane).
    ///
    /// Returns the store and the set of all materialized handles cast to `FakePaneSession` for direct
    /// counter assertions. Order of `allSessions` is unspecified, so callers key off identity, not order.
    private func makeMultiPaneStore() -> (store: WorkspaceStore, fakes: [FakePaneSession]) {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)

        // The default workspace already has one terminal pane; add three more onto the same canvas,
        // one of them the inspector-bearing claudeCode pane.
        store.addPane(kind: .claudeCode)
        store.addPane(kind: .terminal)
        store.addPane(kind: .terminal)

        let fakes = store.allSessions.compactMap { $0 as? FakePaneSession }
        return (store, fakes)
    }

    // MARK: - pauseAll / resumeAll fan-out (every session, exactly once)

    func testPauseAllPausesEverySessionExactlyOnce() async {
        let (store, fakes) = makeMultiPaneStore()

        // Precondition: 4 panes materialized on the canvas, one of them the claudeCode pane.
        XCTAssertEqual(fakes.count, 4, "all four canvas panes are materialized")
        XCTAssertEqual(fakes.filter { $0.kind == .claudeCode }.count, 1,
                       "the inspector-bearing claudeCode pane is among them")
        XCTAssertTrue(fakes.allSatisfy { $0.pauseCount == 0 }, "nothing paused before pauseAll")

        await store.pauseAll()

        // The TaskGroup is AWAITED, so when pauseAll() returns EVERY pause() has already completed.
        for fake in fakes {
            XCTAssertEqual(fake.pauseCount, 1, "pane \(fake.kind) paused exactly once")
            XCTAssertEqual(fake.resumeCount, 0, "pauseAll does not resume")
            XCTAssertEqual(fake.events, [.adopt(fake.id), .pause],
                           "the only events are id-adoption then a single pause")
        }
    }

    func testResumeAllResumesEverySessionExactlyOnceAfterPause() async {
        let (store, fakes) = makeMultiPaneStore()

        await store.pauseAll()
        await store.resumeAll()

        for fake in fakes {
            XCTAssertEqual(fake.pauseCount, 1, "pane \(fake.kind) paused once")
            XCTAssertEqual(fake.resumeCount, 1, "pane \(fake.kind) resumed once")
            // Ordering: adoption, then pause, then resume — resume strictly follows pause.
            XCTAssertEqual(fake.events, [.adopt(fake.id), .pause, .resume],
                           "resume strictly follows the pause for every session")
        }
    }

    func testClaudeCodePaneIsIncludedInTheFanOut() async {
        // The inspector-bearing pane is paused/resumed like any other: FakePaneSession doesn't model
        // the inspector separately — it records the single pause()/resume() the store drives, which is
        // exactly the store's contract (the LivePaneSession internally fans that to connection+inspector).
        let (store, fakes) = makeMultiPaneStore()
        guard let claude = fakes.first(where: { $0.kind == .claudeCode }) else {
            return XCTFail("expected a claudeCode pane in the fixture")
        }

        await store.pauseAll()
        XCTAssertEqual(claude.pauseCount, 1, "the claudeCode pane is paused too")

        await store.resumeAll()
        XCTAssertEqual(claude.resumeCount, 1, "the claudeCode pane is resumed too")
    }

    // MARK: - Video suspend/restore across the fan-out (docs/22 §4)

    /// A `.remoteGUI` pane that is video-active when the app backgrounds must have its video SUSPENDED
    /// by `pauseAll()` (iOS kills an app that strands the UDP/VTDecompress/CADisplayLink stack) and
    /// RESTORED by `resumeAll()`. The restore re-opens at most the set that was already admitted, so it
    /// cannot exceed `liveVideoCap`. Driven through `FakePaneSession`, which mirrors the contract.
    func testVideoPaneSuspendsOnPauseAndRestoresOnResume() async {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        store.addPane(kind: .remoteGUI)
        let videoID = store.focusedPane!                    // the new remoteGUI pane is focused
        XCTAssertTrue(store.activateVideo(videoID), "video pane admitted under the cap")
        let video = store.handle(for: videoID) as! FakePaneSession
        XCTAssertTrue(video.isVideoActive, "active before background")

        await store.pauseAll()
        XCTAssertFalse(video.isVideoActive, "pauseAll suspended the video stack (no stranded socket)")

        await store.resumeAll()
        XCTAssertTrue(video.isVideoActive, "resumeAll restored the video that was active before pause")
    }

    /// A `.remoteGUI` pane that was NOT video-active at background stays inactive after resume — the
    /// restore re-opens only what was admitted, never spuriously activating an idle video pane.
    func testInactiveVideoPaneStaysInactiveAcrossFanOut() async {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        store.addPane(kind: .remoteGUI)
        let videoID = store.focusedPane!
        let video = store.handle(for: videoID) as! FakePaneSession
        XCTAssertFalse(video.isVideoActive, "never activated")

        await store.pauseAll()
        await store.resumeAll()
        XCTAssertFalse(video.isVideoActive, "an idle video pane is not spuriously activated by resume")
    }

    func testFanOutCoversEverySessionOnTheCanvasNotJustTheFocusedPane() async {
        // Only one pane is focused after the fixture build; the rest are unfocused (and may be off the
        // current viewport). pauseAll must still reach them (background pauses the whole app, not just
        // the focused/visible pane).
        let (store, fakes) = makeMultiPaneStore()

        // Sanity: a handle exists for every pane on the canvas (the registry spans the whole canvas).
        let allPaneIDs = store.workspace.canvas.allIDs()
        XCTAssertEqual(Set(fakes.map { $0.id }), Set(allPaneIDs),
                       "every pane on the canvas is materialized")
        XCTAssertGreaterThan(allPaneIDs.count, 1, "more than one pane, so some are unfocused")

        await store.pauseAll()
        XCTAssertTrue(fakes.allSatisfy { $0.pauseCount == 1 },
                      "unfocused panes are paused too, not just the focused pane")
    }

    // MARK: - The fan-out is AWAITED (no fire-and-forget)

    /// The decisive test: `pauseAll()` must NOT return until every session's `pause()` has actually
    /// completed. We register a single gated session whose `pause()` blocks on a continuation, launch
    /// `pauseAll()` on a detached task, prove it is still running while the gate is closed, then release
    /// the gate and prove `pauseAll()` only then completes. A fire-and-forget implementation would let
    /// `pauseAll()` return immediately (while `pause()` is still suspended) — this catches that.
    func testPauseAllAwaitsEverySessionBeforeReturning() async {
        let gate = ContinuationGate()
        let store = WorkspaceStore(makeSession: { GatedFakePaneSession($0, gate: gate) }, liveVideoCap: 2)
        guard let gated = store.allSessions.first as? GatedFakePaneSession else {
            return XCTFail("expected the single gated session")
        }

        // Launch pauseAll on a child task; it should suspend inside the gated pause().
        let pauseAllFinished = Flag()
        let task = Task { @MainActor in
            await store.pauseAll()
            pauseAllFinished.value = true
        }

        // Wait until pause() has actually been entered (the TaskGroup spawned + dispatched it).
        let entered = await waitUntil { gated.pauseEntered }
        XCTAssertTrue(entered, "pauseAll dispatched the session's pause()")

        // While the gate is closed, pauseAll() must NOT have returned (proves it awaits the body).
        XCTAssertFalse(pauseAllFinished.value,
                       "pauseAll has not returned while pause() is still suspended — it is awaited, not fire-and-forget")

        // Release the gate; pauseAll() should now complete.
        gate.release()
        await task.value
        XCTAssertTrue(pauseAllFinished.value, "pauseAll returned only after the suspended pause() completed")
        XCTAssertEqual(gated.pauseCount, 1, "the gated pause ran exactly once")
    }

    /// Same proof for the resume mirror: `resumeAll()` is awaited end-to-end.
    func testResumeAllAwaitsEverySessionBeforeReturning() async {
        let gate = ContinuationGate()
        let store = WorkspaceStore(makeSession: { GatedFakePaneSession($0, gate: gate) }, liveVideoCap: 2)
        guard let gated = store.allSessions.first as? GatedFakePaneSession else {
            return XCTFail("expected the single gated session")
        }

        let resumeAllFinished = Flag()
        let task = Task { @MainActor in
            await store.resumeAll()
            resumeAllFinished.value = true
        }

        let entered = await waitUntil { gated.resumeEntered }
        XCTAssertTrue(entered, "resumeAll dispatched the session's resume()")
        XCTAssertFalse(resumeAllFinished.value,
                       "resumeAll has not returned while resume() is still suspended — it is awaited")

        gate.release()
        await task.value
        XCTAssertTrue(resumeAllFinished.value, "resumeAll returned only after the suspended resume() completed")
        XCTAssertEqual(gated.resumeCount, 1, "the gated resume ran exactly once")
    }

    /// With MULTIPLE gated sessions, `pauseAll()` must await ALL of them: it stays suspended until every
    /// gate is released. This is the multi-session generalization of the awaited-fan-out proof — a
    /// fire-and-forget per-session race would let pauseAll() return with some pauses still pending.
    func testPauseAllAwaitsAllSessionsNotJustTheFirst() async {
        let gate = ContinuationGate()
        // Three panes on the canvas (three gated sessions). Each pause() blocks on the SAME shared gate,
        // which only releases all waiters together — so pauseAll cannot return until all are released.
        let store = WorkspaceStore(makeSession: { GatedFakePaneSession($0, gate: gate) }, liveVideoCap: 2)
        store.addPane(kind: .terminal)
        store.addPane(kind: .terminal)
        let gateds = store.allSessions.compactMap { $0 as? GatedFakePaneSession }
        XCTAssertEqual(gateds.count, 3, "three canvas panes, three gated sessions")

        let finished = Flag()
        let task = Task { @MainActor in
            await store.pauseAll()
            finished.value = true
        }

        // Wait until ALL three pause() bodies have been entered (the whole group is in flight).
        let allEntered = await waitUntil { gate.waiterCount == 3 }
        XCTAssertTrue(allEntered, "all three pause() bodies were dispatched concurrently by the TaskGroup")
        XCTAssertFalse(finished.value, "pauseAll is still suspended while any pause() is pending")

        gate.release()
        await task.value
        XCTAssertTrue(finished.value, "pauseAll returned only after EVERY session's pause() completed")
        XCTAssertTrue(gateds.allSatisfy { $0.pauseCount == 1 }, "each gated session paused exactly once")
    }

    // MARK: - Empty / idempotency edges

    func testPauseAllOnEmptyRegistryIsANoOp() async {
        // A store with no panes (close the only pane → empty canvas). pauseAll must not hang or crash
        // with an empty registry.
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let onlyPane = store.focusedPane!
        store.closePane(onlyPane)        // last pane → empty canvas
        await store.quiesce()            // let the orphan teardown settle
        XCTAssertTrue(store.allSessions.isEmpty, "registry is empty")

        await store.pauseAll()           // must simply return
        await store.resumeAll()
        XCTAssertTrue(store.allSessions.isEmpty, "still empty; fan-out over nothing is a clean no-op")
    }

    func testRepeatedPauseAllAccumulatesCallsWithoutResume() async {
        // pauseAll is not idempotent at the count level (it forwards a pause() each time). Two calls
        // with no resume in between => pauseCount == 2. This documents the store does not de-dup.
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let fake = store.allSessions.first as! FakePaneSession

        await store.pauseAll()
        await store.pauseAll()
        XCTAssertEqual(fake.pauseCount, 2, "each pauseAll forwards a pause(); the store does not coalesce")
        XCTAssertEqual(fake.resumeCount, 0)
    }

    // MARK: - Helpers

    /// Polls a `@MainActor` predicate until true or the deadline passes (avoids fixed sleeps). Mirrors
    /// the `waitUntil` used by the connection tests.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

// MARK: - Test-only mutable flag (main-actor isolated)

/// A trivial main-actor-isolated boolean the awaited-fan-out tests flip from inside a child `Task` and
/// read from the test body. Both run on the main actor (the store + tests are `@MainActor`), so the
/// access is serialized without any locking; it exists only because a `var` captured by a closure can't
/// be observed back here otherwise.
@MainActor
private final class Flag {
    var value = false
}

// MARK: - ContinuationGate (the controllable suspension point)

/// A main-actor gate that suspends every caller of ``wait()`` until ``release()`` is called once, after
/// which all current and future waiters proceed immediately. The awaited-fan-out tests use it to hold a
/// session's `pause()`/`resume()` suspended so they can observe that `pauseAll()`/`resumeAll()` have NOT
/// returned while the body is parked — the proof that the fan-out awaits each session.
///
/// Main-actor isolated (no locks needed): the store, the sessions, and the tests all run on the main
/// actor, so the waiter bookkeeping is single-threaded by construction.
@MainActor
private final class ContinuationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    /// Number of callers currently parked in ``wait()`` (lets a test observe that the whole TaskGroup
    /// reached its suspension points before releasing).
    var waiterCount: Int { continuations.count }

    /// Suspends until the gate is released. Returns immediately if already released.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuations.append(cont)
        }
    }

    /// Opens the gate: resumes all parked waiters and lets future ``wait()`` calls pass through.
    func release() {
        isOpen = true
        let parked = continuations
        continuations.removeAll()
        for cont in parked { cont.resume() }
    }
}

// MARK: - GatedFakePaneSession (a FakePaneSession whose lifecycle suspends)

/// A ``PaneSessionHandle`` test double identical to ``FakePaneSession`` except that `pause()` and
/// `resume()` SUSPEND on a shared ``ContinuationGate`` before recording. This is what makes the
/// "awaited fan-out" assertion possible: a plain counter double's `pause()` completes synchronously, so
/// it cannot distinguish an awaited `TaskGroup` from fire-and-forget. With this double, the test can
/// observe `pause()` entered-but-not-finished and prove `pauseAll()` is still suspended.
///
/// It conforms to ``PaneSessionHandle`` AND the store-internal ``PaneSessionIDAdopting`` exactly as the
/// real sessions do, so the store materializes and adopts it the same way (no `HostServer`/`AislopdeskClient`).
@MainActor
@Observable
private final class GatedFakePaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private let gate: ContinuationGate

    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var teardownCount = 0

    /// Flips `true` the instant `pause()`/`resume()` is entered (before suspending on the gate), so a
    /// test can wait for the body to be in flight without racing the suspension.
    private(set) var pauseEntered = false
    private(set) var resumeEntered = false

    private(set) var isVideoActive = false

    init(_ spec: PaneSpec, gate: ContinuationGate) {
        self.id = PaneID()
        self.kind = spec.kind
        self.gate = gate
    }

    func adopt(id: PaneID) { self.id = id }

    func setVideoActive(_ active: Bool) {
        guard kind == .remoteGUI else { return }
        isVideoActive = active
    }

    func pause() async {
        pauseEntered = true
        await gate.wait()      // suspend until the test releases the gate
        pauseCount += 1
    }

    func resume() async {
        resumeEntered = true
        await gate.wait()
        resumeCount += 1
    }

    func teardown() async {
        teardownCount += 1
    }
}
