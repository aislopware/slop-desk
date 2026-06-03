import XCTest
import Foundation
@testable import RworkClientUI

// MARK: - LiveVideoCapTests

/// Pins the `liveVideoCap` admission policy on ``WorkspaceStore`` (docs/22 §7): the concurrent
/// live-video ceiling that protects the PATH 2 resource budget (2N UDP sockets / N
/// `VTDecompressionSession` / N `CVDisplayLink`). The cap is enforced at **activation**
/// (``WorkspaceStore/activateVideo(_:)``), NOT at materialization — `reconcile()` always
/// materializes an IDLE `.remoteGUI` session; the store only admits its video stack when a slot is
/// free.
///
/// Everything here injects ``FakePaneSession`` through the `makeSession` seam — never a `RworkClient`
/// or a `HostServer`. The double's `setVideoActive` flips its `isVideoActive` flag UNCONDITIONALLY
/// for `.remoteGUI` (no internal cap), so the cap under test is purely the store's: we exercise it
/// only through `store.activateVideo` / `store.deactivateVideo`, never by poking the double.
///
/// The asserted contract:
/// - the first `liveVideoCap` `.remoteGUI` panes activate (`true`); the next is GATED (`false`) and
///   left inactive (the view shows the gated placeholder);
/// - re-activating an already-active pane is an idempotent `true`;
/// - `deactivateVideo` frees a slot, after which a previously-gated pane CAN activate. The store
///   cannot flip a pane's `isVideoActive` itself (admission is view-driven on appear, docs/22 §7), but
///   it DOES emit a reactive nudge (``WorkspaceStore/videoPromotionGeneration``, ITEM #2) on every
///   slot-freeing event so the on-screen gated leaves observe it and re-attempt admission through the
///   still-cap-checked `activateVideo`;
/// - `terminal` / `claudeCode` panes are NEVER gated by the video cap (and never count against it):
///   `activateVideo` returns `false` for them because they are non-video, not because of the cap.
@MainActor
final class LiveVideoCapTests: XCTestCase {

    // MARK: - Fixtures

    /// A store wired with the test double and an explicit cap. Never constructs a real client/host.
    private func makeStore(cap: Int) -> WorkspaceStore {
        WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: cap)
    }

    /// Casts a handle to the concrete double so a test can read its recorded video state.
    private func fake(_ handle: (any PaneSessionHandle)?) -> FakePaneSession {
        guard let f = handle as? FakePaneSession else {
            fatalError("expected a FakePaneSession from the injected seam")
        }
        return f
    }

    /// Builds a store whose ONLY tab is a tree of `n` `.remoteGUI` leaves (one root leaf + `n−1`
    /// splits), returning the store and the leaf ids in tree pre-order. The store is `restoring:` a
    /// single-remoteGUI-tab workspace (NOT `addTab`, which would leave the default terminal tab in
    /// the registry and contaminate the cap accounting). Each split adds exactly one new `.remoteGUI`
    /// session; reconcile materializes them all IDLE (none video-active yet).
    private func makeStoreWithRemoteGUILeaves(_ n: Int, cap: Int) -> (store: WorkspaceStore, ids: [PaneID]) {
        precondition(n >= 1)
        let rootID = PaneID()
        let spec = PaneSpec(kind: .remoteGUI, title: "Remote window")
        let tab = Tab(name: "Remote window", root: .leaf(rootID, spec), focusedPane: rootID)
        let ws = Workspace(tabs: [tab], activeTabID: tab.id)
        let store = WorkspaceStore(restoring: ws, makeSession: { FakePaneSession($0) }, liveVideoCap: cap)

        var ids = store.activeTab!.root.allLeafIDs()
        // Split the most-recently-added leaf to grow the tree to `n` remoteGUI leaves.
        while ids.count < n {
            store.split(ids.last!, axis: .horizontal, kind: .remoteGUI)
            ids = store.activeTab!.root.allLeafIDs()
        }
        XCTAssertEqual(ids.count, n, "tree should have exactly \(n) remoteGUI leaves")
        XCTAssertEqual(store.allSessions.count, n, "registry holds only the remoteGUI leaves (no stray default tab)")
        return (store, ids)
    }

    // MARK: - Materialization is idle (cap is NOT a materialization gate)

    /// `reconcile()` materializes one IDLE `.remoteGUI` session per leaf regardless of the cap —
    /// the cap only bites at activation. After building 3 leaves under cap=2, all 3 sessions exist
    /// and none is video-active.
    func testRemoteGUIPanesMaterializeIdleEvenBeyondCap() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)

        XCTAssertEqual(store.allSessions.count, 3, "all leaves materialize, even beyond the cap")
        for id in ids {
            let h = store.handle(for: id)
            XCTAssertNotNil(h, "leaf \(id) has a live session")
            XCTAssertEqual(h?.kind, .remoteGUI)
            XCTAssertFalse(h!.isVideoActive, "materialized sessions are idle — no video activated")
        }
        // Registry-key invariant holds: one handle per leaf, keyed by leaf id.
        XCTAssertEqual(Set(store.allSessions.map { $0.id }),
                       Set(store.activeTab!.root.allLeafIDs()))
    }

    // MARK: - The cap admits up to N, then gates

    /// With cap=2, the first two `.remoteGUI` panes activate (`true`) and the third is GATED:
    /// `activateVideo` returns `false` and leaves the pane inactive.
    func testActivateAdmitsUpToCapThenGatesThird() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)

        XCTAssertTrue(store.activateVideo(ids[0]), "1st video pane admitted")
        XCTAssertTrue(store.activateVideo(ids[1]), "2nd video pane admitted (at the cap)")
        XCTAssertFalse(store.activateVideo(ids[2]), "3rd is gated — cap saturated by 2 others")

        // The first two hold live video; the gated third stays idle.
        XCTAssertTrue(fake(store.handle(for: ids[0])).isVideoActive)
        XCTAssertTrue(fake(store.handle(for: ids[1])).isVideoActive)
        XCTAssertFalse(fake(store.handle(for: ids[2])).isVideoActive, "gated pane never had setVideoActive(true)")

        // The double recorded exactly the two admitted activations, none for the gated pane.
        XCTAssertEqual(fake(store.handle(for: ids[0])).events, [.adopt(ids[0]), .videoActive(true)])
        XCTAssertEqual(fake(store.handle(for: ids[2])).events, [.adopt(ids[2])],
                       "gated pane saw only its adopt — the store never called setVideoActive on it")

        // Exactly cap panes are live.
        let activeCount = store.allSessions.filter { $0.kind == .remoteGUI && $0.isVideoActive }.count
        XCTAssertEqual(activeCount, store.liveVideoCap)
    }

    /// Re-activating an already-active pane is an idempotent `true` and does NOT consume a second
    /// slot (so it cannot accidentally push the live count past the cap).
    func testActivateAlreadyActiveIsIdempotentTrue() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))

        XCTAssertTrue(store.activateVideo(ids[0]), "already-active ⇒ idempotent true")
        XCTAssertTrue(store.activateVideo(ids[1]), "the second real slot is still free")
        XCTAssertFalse(store.activateVideo(ids[2]), "cap still 2 — the re-activation did not free or consume a slot")

        // ids[0] recorded only ONE setVideoActive(true) despite two activate calls.
        let events0 = fake(store.handle(for: ids[0])).events
        XCTAssertEqual(events0.filter { $0 == .videoActive(true) }.count, 1,
                       "idempotent re-activation does not re-call setVideoActive")
    }

    // MARK: - Freeing a slot

    /// `deactivateVideo` frees a slot; a previously-gated pane can then activate. The store does not
    /// flip `isVideoActive` itself — it only becomes active when the view re-requests it via
    /// `activateVideo` (docs/22 §7: activation is view-driven on appear). The store DOES bump
    /// ``WorkspaceStore/videoPromotionGeneration`` here (ITEM #2) so an on-screen gated leaf observes the
    /// freed slot and re-attempts; this test drives that re-attempt explicitly (the view's `.onChange`
    /// is exercised by the dedicated promotion-generation tests below).
    func testDeactivateFreesSlotForPreviouslyGatedPane() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]), "third gated while two are live")

        // Free slot 0.
        store.deactivateVideo(ids[0])
        XCTAssertFalse(fake(store.handle(for: ids[0])).isVideoActive, "slot 0 freed")
        // The store never flips liveness on its own: the previously-gated pane stays idle until it
        // re-requests admission (the promotion nudge only TRIGGERS that re-request in the view layer).
        XCTAssertFalse(fake(store.handle(for: ids[2])).isVideoActive,
                       "store does not flip isVideoActive itself — it only nudges the view to re-request")

        // The previously-gated pane now activates because a slot is free.
        XCTAssertTrue(store.activateVideo(ids[2]), "a freed slot admits the previously-gated pane")
        XCTAssertTrue(fake(store.handle(for: ids[2])).isVideoActive)

        // Still exactly cap live (ids[1] + ids[2]); ids[0] is idle.
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([ids[1], ids[2]]))
    }

    /// `deactivateVideo` on a pane that is not active is a harmless no-op and frees nothing extra.
    func testDeactivateInactivePaneIsNoOp() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        // ids[1] is idle; deactivating it should not throw or flip anything.
        store.deactivateVideo(ids[1])
        XCTAssertFalse(fake(store.handle(for: ids[1])).isVideoActive)
        XCTAssertTrue(fake(store.handle(for: ids[0])).isVideoActive, "the active pane is untouched")
    }

    // MARK: - cap respects OTHER panes only (the self-exclusion in activateVideo)

    /// The cap counts only OTHER active video panes (the `$0.id != id` filter in `activateVideo`),
    /// so with cap=1 the single admitted pane can be re-activated even though it is itself the one
    /// occupying the slot.
    func testCapOfOneAdmitsOneAndReactivatesSelf() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 1)
        XCTAssertTrue(store.activateVideo(ids[0]), "the single slot admits the first pane")
        XCTAssertFalse(store.activateVideo(ids[1]), "no slot left for a second pane")
        XCTAssertTrue(store.activateVideo(ids[0]), "self re-activation succeeds — the cap excludes self")
    }

    // MARK: - non-video kinds are never gated by the cap

    /// `terminal` and `claudeCode` panes are not gated by the video cap — `activateVideo` returns
    /// `false` for them because they are NON-VIDEO (not because the cap is saturated), they never
    /// flip `isVideoActive`, and they never consume a video slot.
    func testTerminalAndClaudeCodeAreNeverGatedAndNeverConsumeSlots() {
        // cap=2, but saturate it with two live remoteGUI panes first.
        let store = makeStore(cap: 2)
        store.addTab(kind: .remoteGUI)                         // tab: one remoteGUI leaf
        let guiRoot = store.activeTab!.root.allLeafIDs()[0]
        store.split(guiRoot, axis: .horizontal, kind: .remoteGUI)
        let guiIDs = store.activeTab!.root.allLeafIDs()        // two remoteGUI leaves
        XCTAssertTrue(store.activateVideo(guiIDs[0]))
        XCTAssertTrue(store.activateVideo(guiIDs[1]))          // cap now saturated

        // Add terminal + claudeCode panes in a separate tab.
        store.addTab(kind: .terminal)
        let terminalID = store.activeTab!.root.allLeafIDs()[0]
        store.split(terminalID, axis: .vertical, kind: .claudeCode)
        let mixedIDs = store.activeTab!.root.allLeafIDs()
        let claudeID = mixedIDs.first { store.handle(for: $0)?.kind == .claudeCode }!

        // activateVideo is a definitional false for non-video kinds — regardless of cap state.
        XCTAssertFalse(store.activateVideo(terminalID), "terminal is non-video, not cap-gated")
        XCTAssertFalse(store.activateVideo(claudeID), "claudeCode is non-video, not cap-gated")

        // They never flipped a video flag and never consumed a slot.
        XCTAssertFalse(store.handle(for: terminalID)!.isVideoActive)
        XCTAssertFalse(store.handle(for: claudeID)!.isVideoActive)
        XCTAssertEqual(fake(store.handle(for: terminalID)).events, [.adopt(terminalID)],
                       "non-video pane saw only its adopt — no videoActive event")

        // The two real video panes are still the only ones live (the cap is unchanged by the
        // non-video activate attempts).
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([guiIDs[0], guiIDs[1]]))
    }

    /// `activateVideo` on an unknown / torn-down pane id is a safe `false` (no registered handle).
    func testActivateUnknownPaneIsFalse() {
        let store = makeStore(cap: 2)
        XCTAssertFalse(store.activateVideo(PaneID()), "no handle for an unregistered id")
    }

    // MARK: - the freed slot survives an unrelated reconcile

    /// Activating, then a structural mutation that does NOT touch the video leaves (adding a
    /// terminal tab → reconcile), leaves the video activation state intact: reconcile never
    /// re-materializes or de-activates existing sessions, so the cap accounting is stable across
    /// reconciles. After the unrelated reconcile the gated pane is still gated.
    func testVideoActivationSurvivesUnrelatedReconcile() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]))

        // An unrelated structural mutation (new terminal tab) triggers reconcile but adds only a
        // terminal leaf — the existing remoteGUI sessions (and their video state) are untouched.
        store.addTab(kind: .terminal)
        await store.quiesce()   // no orphans here, but pin the teardown-completion seam regardless

        XCTAssertTrue(fake(store.handle(for: ids[0])).isVideoActive, "video pane survived reconcile")
        XCTAssertTrue(fake(store.handle(for: ids[1])).isVideoActive)
        XCTAssertFalse(store.activateVideo(ids[2]), "still gated — the cap accounting is unchanged")

        // The original handles were not rebuilt (same instances, same single activation event each).
        XCTAssertEqual(fake(store.handle(for: ids[0])).events.filter { $0 == .videoActive(true) }.count, 1)
    }

    // MARK: - closing an ACTIVE video pane frees its slot (teardown path)

    /// Closing a pane that holds a live video slot removes it from the registry synchronously and tears
    /// its session down asynchronously. The closed pane's video stack is NOT released until its
    /// `teardown()` completes, so the cap keeps counting it (via `tearingDownVideo`, ITEM #3) until then:
    /// the previously-gated pane can only activate AFTER `quiesce()` confirms the teardown ran and the
    /// slot is genuinely free.
    func testClosingActiveVideoPaneFreesSlot() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]), "gated while ids[0] and ids[1] are live")

        let closed = fake(store.handle(for: ids[0]))    // grab the double before it leaves the registry

        // Close the first live video pane (a non-last leaf, so the tab survives).
        store.closePane(ids[0])

        // Synchronously: it is gone from the registry and the invariant holds.
        XCTAssertNil(store.handle(for: ids[0]), "closed pane removed from the registry synchronously")
        XCTAssertEqual(Set(store.allSessions.map { $0.id }),
                       Set(store.activeTab!.root.allLeafIDs()),
                       "registry keys == leaf ids the instant closePane returns")

        // The async teardown completes only after quiesce(); only THEN is the closed pane's video stack
        // actually released, freeing the slot for the previously-gated pane (ITEM #3 — the cap counts
        // in-flight teardown, so a same-tick reopen cannot overlap two live stacks).
        await store.quiesce()
        XCTAssertEqual(closed.teardownCount, 1, "the closed video session was torn down exactly once")
        XCTAssertEqual(closed.events.last, .teardown)

        // With the slot genuinely freed, the gated pane admits.
        XCTAssertTrue(store.activateVideo(ids[2]), "the freed slot admits the previously-gated pane")

        // Final live set: ids[1] (still live) + ids[2] (newly admitted).
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([ids[1], ids[2]]))
    }

    // MARK: - BUG-D: a superseded debounced save is skipped via the saveGeneration guard

    /// BUG-D — `saveImmediately()` (and a newer `scheduleSave`) must reliably win over an in-flight
    /// debounced write that has raced PAST its `Task.sleep`: `Task.cancel()` cannot stop a task already
    /// inside the write, so the debounced path re-checks `saveGeneration` ON THE MAIN ACTOR right before
    /// writing and SKIPS if superseded. This asserts that exact generation-guard logic through the
    /// `saveGeneration` seam — the SAME predicate (``WorkspaceStore/isCurrentSaveGeneration(_:)``) the
    /// production write path consults — so no stale snapshot can win the last atomic rename. No real
    /// file race is needed: the supersession decision is a pure MainActor `Int` compare.
    func testSupersededDebouncedSaveIsSkippedByGenerationGuard() {
        // A store backed by a temp-file persistence (so the generation actually bumps) with a LONG
        // debounce, so the scheduled save parks in its sleep and never fires during the test.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rwork-bugd-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let persistence = WorkspacePersistence(fileURL: tmp)
        let store = WorkspaceStore(
            restoring: nil,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: persistence,
            saveDebounce: .seconds(3600)   // effectively never fires during the test
        )

        // A mutation schedules a debounced save: it bumps the generation and CAPTURES it (gen0). The
        // task parks on its hour-long sleep, so its write has NOT run.
        store.addTab(kind: .terminal)
        let gen0 = store.saveGeneration
        XCTAssertGreaterThan(gen0, 0, "scheduleSave bumped the generation for the just-scheduled write")
        XCTAssertTrue(store.isCurrentSaveGeneration(gen0),
                      "the just-scheduled debounced write is the current generation — it would write")

        // saveImmediately() bumps the generation again (and writes synchronously NOW). The earlier
        // debounced task's captured gen0 is now STALE.
        store.saveImmediately()
        let genAfterImmediate = store.saveGeneration
        XCTAssertGreaterThan(genAfterImmediate, gen0, "saveImmediately bumped the generation past the debounced one")

        // THE GUARD: were the gen0 debounced task to wake and reach its pre-write re-check now, the
        // predicate the production path consults reports it superseded — so it SKIPS the write and the
        // saveImmediately() snapshot keeps the file. (A stale rename can never win.)
        XCTAssertFalse(store.isCurrentSaveGeneration(gen0),
                       "the superseded debounced write is no longer current — it will skip its write")
        XCTAssertTrue(store.isCurrentSaveGeneration(genAfterImmediate),
                      "only the latest generation is current")

        // saveImmediately wrote synchronously: the file exists and decodes to the current tree shape.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path),
                      "saveImmediately() wrote the file synchronously, winning over the parked debounced save")
        let onDisk = persistence.load()
        XCTAssertEqual(onDisk.tabs.count, store.workspace.tabs.count,
                       "the file reflects the saveImmediately() snapshot (2 tabs), not a stale one")

        // A fresh mutation schedules another debounced save, bumping the generation once more — and the
        // prior, now-superseded gen0 is STILL not current (the guard is monotone).
        store.addTab(kind: .terminal)
        XCTAssertGreaterThan(store.saveGeneration, genAfterImmediate, "a new mutation bumps the generation again")
        XCTAssertFalse(store.isCurrentSaveGeneration(gen0), "an old generation never becomes current again")
    }

    // MARK: - same-tick close+reopen does NOT exceed the ceiling (ITEM #3)

    /// The load-bearing ITEM #3 case: a `.remoteGUI` pane that closed while video-active keeps its slot
    /// occupied until its teardown ACTUALLY releases the video stack. We hold the teardown suspended on
    /// the opt-in `FakeTeardownGate`, so the closed pane is gone from the registry but still tearing
    /// down — and a new pane opened the same tick must NOT be admitted (its stack would overlap the
    /// not-yet-released one, breaching the 2-pane ceiling). Only after the gate releases and `quiesce()`
    /// confirms the release does the slot free.
    func testSameTickCloseReopenDoesNotExceedCeiling() async {
        // cap=2, two remoteGUI leaves both live.
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 2)
        let gate = FakeTeardownGate()
        // Install the blocking gate on the pane we will close, so its teardown parks in flight.
        fake(store.handle(for: ids[0])).teardownGate = gate

        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]), "cap=2 saturated by two live video panes")

        // Close ids[0] (a non-last leaf → the tab survives). Its teardown will park on the gate, so its
        // video stack is NOT yet released — `tearingDownVideo` holds its id.
        store.closePane(ids[0])
        XCTAssertNil(store.handle(for: ids[0]), "closed pane gone from the registry synchronously")

        // Same tick, open a replacement remoteGUI pane (split the survivor). It materializes idle.
        store.split(ids[1], axis: .horizontal, kind: .remoteGUI)
        let reopened = store.activeTab!.root.allLeafIDs().first { $0 != ids[1] }!

        // The replacement must be GATED: ids[1] is live (1) + ids[0] still tearing down (1) = the cap of
        // 2 is still occupied. Admitting it would transiently run THREE video stacks.
        XCTAssertFalse(store.activateVideo(reopened),
                       "same-tick reopen gated — the closing pane's stack is not released yet")

        // Release the teardown and drain. Now ids[0]'s stack is gone; the slot frees.
        gate.release()
        await store.quiesce()

        XCTAssertTrue(store.activateVideo(reopened),
                      "once the closed pane's teardown released its stack, the reopened pane admits")
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([ids[1], reopened]), "exactly cap=2 live; no overlap ever exceeded it")
    }

    /// An in-flight teardown of a NON-active (never video-activated) `.remoteGUI` pane must NOT gate the
    /// cap: it was never holding a video stack, so `reconcile()` does not record it in
    /// `tearingDownVideo`, and a same-tick reopen activates immediately even while its teardown is
    /// parked. (The cap counts only stacks that were genuinely live.)
    func testInFlightTeardownOfNonActiveVideoPaneDoesNotGate() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 2)
        let gate = FakeTeardownGate()
        fake(store.handle(for: ids[0])).teardownGate = gate

        // ids[0] is materialized IDLE — never activated, so it holds NO video stack.
        XCTAssertFalse(store.handle(for: ids[0])!.isVideoActive)
        XCTAssertTrue(store.activateVideo(ids[1]), "only ids[1] is live (1 of 2)")

        // Close the idle ids[0]; its teardown parks on the gate.
        store.closePane(ids[0])
        XCTAssertNil(store.handle(for: ids[0]))

        // Open a replacement. Because the closing pane was NEVER video-active, it is not counted in
        // flight — so with only ids[1] live (1 of 2) the reopened pane admits right now.
        store.split(ids[1], axis: .horizontal, kind: .remoteGUI)
        let reopened = store.activeTab!.root.allLeafIDs().first { $0 != ids[1] }!
        XCTAssertTrue(store.activateVideo(reopened),
                      "an in-flight teardown of a NON-active pane does not occupy a cap slot")

        gate.release()
        await store.quiesce()
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([ids[1], reopened]))
    }

    /// `quiesce()` clears the in-flight video accounting defensively: after it returns, no
    /// `.remoteGUI` stack can still be tearing down, so a fresh activation sees a fully-free cap (ITEM
    /// #3). Proven by closing a live video pane, draining, and confirming a new pane admits up to the
    /// full cap again with zero phantom in-flight slots stranded.
    func testQuiesceClearsInFlightVideoAccounting() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 1)   // cap=1 so any phantom slot would bite
        let gate = FakeTeardownGate()
        fake(store.handle(for: ids[0])).teardownGate = gate

        XCTAssertTrue(store.activateVideo(ids[0]), "the single slot admits ids[0]")
        XCTAssertFalse(store.activateVideo(ids[1]), "cap=1 saturated")

        store.closePane(ids[0])     // ids[0] was active → recorded in tearingDownVideo, parked on the gate
        XCTAssertFalse(store.activateVideo(ids[1]),
                       "still gated — the closing pane's stack is in flight and counts against cap=1")

        gate.release()
        await store.quiesce()       // drains teardown AND defensively clears tearingDownVideo

        // The single slot is genuinely free again — no stranded in-flight accounting.
        XCTAssertTrue(store.activateVideo(ids[1]), "after quiesce the cap-1 slot is fully free")
    }

    // MARK: - ITEM #2: reactive promotion-generation nudge on slot-freeing events

    /// Deactivating a LIVE video pane bumps ``WorkspaceStore/videoPromotionGeneration`` exactly once, so
    /// the view layer's `.onChange` re-attempts admission for a gated on-screen sibling (the store still
    /// does NOT flip liveness — see ``testPromotionGenerationDoesNotItselfPromote``).
    func testDeactivateBumpsPromotionGeneration() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        let before = store.videoPromotionGeneration

        store.deactivateVideo(ids[0])
        XCTAssertEqual(store.videoPromotionGeneration, before + 1,
                       "deactivating a live video pane is a slot-freeing event ⇒ one promotion nudge")
    }

    /// Deactivating a pane that was NOT video-active is a no-op for liveness AND must NOT bump the
    /// promotion generation (the `wasActive` guard): nothing freed, so re-triggering gated siblings'
    /// retries would be wasted churn.
    func testDeactivateInactivePaneDoesNotBumpPromotionGeneration() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 2)
        // ids[1] is materialized IDLE — never activated.
        XCTAssertFalse(store.handle(for: ids[1])!.isVideoActive)
        let before = store.videoPromotionGeneration

        store.deactivateVideo(ids[1])
        XCTAssertEqual(store.videoPromotionGeneration, before,
                       "a no-op deactivate freed nothing ⇒ no promotion nudge")

        // A deactivate on an unknown id is likewise inert.
        store.deactivateVideo(PaneID())
        XCTAssertEqual(store.videoPromotionGeneration, before,
                       "deactivating an unknown id frees nothing ⇒ no promotion nudge")
    }

    /// The promotion nudge is JUST a signal — bumping it (via a slot-freeing event) does NOT itself flip
    /// any pane's `isVideoActive`. The store can never promote a pane on its own; the gated pane stays
    /// idle until a view re-requests admission through `activateVideo` (the nudge only triggers that).
    func testPromotionGenerationDoesNotItselfPromote() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]), "ids[2] gated while two are live")

        let beforeGen = store.videoPromotionGeneration
        store.deactivateVideo(ids[0])   // slot-freeing event → bumps the generation
        XCTAssertGreaterThan(store.videoPromotionGeneration, beforeGen, "the nudge fired")

        // The bump did NOT flip the gated pane: the store does not auto-promote, only the view does.
        XCTAssertFalse(fake(store.handle(for: ids[2])).isVideoActive,
                       "the promotion nudge does not itself activate any pane")
        // And the just-deactivated pane is genuinely off.
        XCTAssertFalse(fake(store.handle(for: ids[0])).isVideoActive)
    }

    /// Closing an ACTIVE video pane (reconcile orphan branch) is also a slot-freeing event, so it bumps
    /// the promotion generation — so closing a live video pane nudges its gated siblings to retry (ITEM
    /// #2). Closing a NON-active video pane frees no slot and must not bump.
    func testClosingActiveVideoPaneBumpsPromotionGeneration() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]), "ids[2] gated while two are live")

        let before = store.videoPromotionGeneration
        store.closePane(ids[0])         // ids[0] was video-active → orphan branch bumps the generation
        XCTAssertEqual(store.videoPromotionGeneration, before + 1,
                       "closing an active video pane is a slot-freeing event ⇒ one promotion nudge")
        await store.quiesce()           // drain the orphan teardown so the next close is clean

        // Closing a pane that was NEVER video-active frees nothing ⇒ no further bump.
        let afterClose = store.videoPromotionGeneration
        XCTAssertFalse(store.handle(for: ids[2])!.isVideoActive, "ids[2] was never admitted")
        store.closePane(ids[2])
        XCTAssertEqual(store.videoPromotionGeneration, afterClose,
                       "closing a non-active video pane frees no slot ⇒ no promotion nudge")
        await store.quiesce()
    }

    // MARK: - BUG-A: an unconfigured remote pane shows the entry form, not the cap placeholder

    /// The PURE display decision (``RemoteGUIDisplay/resolve(admitted:configured:)``) distinguishes the
    /// two false-activation reasons (BUG-A): an admitted pane is `.live`; an UNconfigured one shows the
    /// `.entryForm` (so the user can enter host/port); only a CONFIGURED-but-refused pane shows `.gated`
    /// (the cap-saturated placeholder).
    func testRemoteGUIDisplayResolvesEntryFormWhenUnconfigured() {
        // Admitted always wins (live video), regardless of configured state.
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: true, configured: true), .live)
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: true, configured: false), .live)
        // Not admitted + not configured ⇒ entry form (BUG-A: no host/port yet, nothing to gate).
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: false), .entryForm)
        // Not admitted + configured ⇒ the cap-saturated placeholder.
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: true), .gated)
    }

    /// A fresh `.remoteGUI` pane created with no video endpoint (New Tab/split → Remote Window) has an
    /// UNconfigured ``RemoteWindowModel`` (`canOpen == false`), so even when the cap is saturated its
    /// display resolves to `.entryForm` — NOT `.gated`. This is the BUG-A invariant: an unconfigured pane
    /// can always reach its host/port form (it was previously stuck forever on the cap placeholder).
    func testUnconfiguredRemoteGUIPaneIsNotCapGatedInDisplay() {
        // Build a live (production) remoteGUI session with no video endpoint, mirroring Tab.make/split.
        let session = WorkspaceStore.liveMakeSession()(PaneSpec(kind: .remoteGUI, title: "Remote window"))
        let live = session as! LivePaneSession
        XCTAssertNotNil(live.remoteWindow, "a remoteGUI session always has a RemoteWindowModel")
        XCTAssertFalse(live.remoteWindow!.canOpen, "a fresh unconfigured model cannot open (empty fields)")

        // Even un-admitted (cap saturated, activateVideo would return false), the display is the entry
        // form because the model is not configured — never the cap placeholder.
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: live.remoteWindow!.canOpen),
                       .entryForm)

        // Once the user dials in a valid endpoint, the model becomes configured, so an un-admitted pane
        // would now correctly show the cap placeholder (cap is the real reason it cannot decode).
        live.remoteWindow!.host = "host.example"
        live.remoteWindow!.mediaPort = "9000"
        live.remoteWindow!.cursorPort = "9001"
        live.remoteWindow!.windowID = "42"
        XCTAssertTrue(live.remoteWindow!.canOpen, "a fully-entered model can open")
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: live.remoteWindow!.canOpen),
                       .gated)
    }
}
