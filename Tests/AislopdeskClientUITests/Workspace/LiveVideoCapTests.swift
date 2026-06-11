import XCTest
import Foundation
import AislopdeskTransport
@testable import AislopdeskClientUI

// MARK: - LiveVideoCapTests

/// Pins the `liveVideoCap` admission policy on ``WorkspaceStore`` (docs/22 §7): the concurrent
/// live-video ceiling that protects the PATH 2 resource budget (2N UDP sockets / N
/// `VTDecompressionSession` / N `CVDisplayLink`). The cap is enforced at **activation**
/// (``WorkspaceStore/activateVideo(_:)``), NOT at materialization — `reconcile()` always
/// materializes an IDLE `.remoteGUI` session; the store only admits its video stack when a slot is
/// free.
///
/// Everything here injects ``FakePaneSession`` through the `makeSession` seam — never a `AislopdeskClient`
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

    /// Builds a store whose canvas is `n` `.remoteGUI` panes (one root pane + `n−1` added panes),
    /// returning the store and the pane ids in canvas order. The store is `restoring:` a
    /// single-remoteGUI-pane canvas workspace (NOT the default terminal canvas, which would leave a
    /// stray terminal pane in the registry and contaminate the cap accounting). Each `addPane` adds
    /// exactly one new `.remoteGUI` session; reconcile materializes them all IDLE (none video-active
    /// yet).
    private func makeStoreWithRemoteGUILeaves(_ n: Int, cap: Int, videoTeardownSettle: Duration = .zero) -> (store: WorkspaceStore, ids: [PaneID]) {
        precondition(n >= 1)
        let rootID = PaneID()
        let spec = PaneSpec(kind: .remoteGUI, title: "Remote window")
        let ws = Workspace.make(panes: [(rootID, spec)])
        let store = WorkspaceStore(restoring: ws, makeSession: { FakePaneSession($0) }, liveVideoCap: cap, videoTeardownSettle: videoTeardownSettle)

        var ids = store.workspace.canvas.allIDs()
        // Add remoteGUI panes to grow the canvas to `n` remoteGUI panes.
        while ids.count < n {
            store.addPane(kind: .remoteGUI)
            ids = store.workspace.canvas.allIDs()
        }
        XCTAssertEqual(ids.count, n, "canvas should have exactly \(n) remoteGUI panes")
        XCTAssertEqual(store.allSessions.count, n, "registry holds only the remoteGUI panes (no stray default pane)")
        return (store, ids)
    }

    // MARK: - Materialization is idle (cap is NOT a materialization gate)

    /// `reconcile()` materializes one IDLE `.remoteGUI` session per pane regardless of the cap —
    /// the cap only bites at activation. After building 3 panes under cap=2, all 3 sessions exist
    /// and none is video-active.
    func testRemoteGUIPanesMaterializeIdleEvenBeyondCap() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)

        XCTAssertEqual(store.allSessions.count, 3, "all panes materialize, even beyond the cap")
        for id in ids {
            let h = store.handle(for: id)
            XCTAssertNotNil(h, "pane \(id) has a live session")
            XCTAssertEqual(h?.kind, .remoteGUI)
            XCTAssertFalse(h!.isVideoActive, "materialized sessions are idle — no video activated")
        }
        // Registry-key invariant holds: one handle per pane, keyed by pane id.
        XCTAssertEqual(Set(store.allSessions.map { $0.id }),
                       Set(store.workspace.canvas.allIDs()))
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
        // cap=2, saturated by two live remoteGUI panes on the canvas.
        let (store, guiIDs) = makeStoreWithRemoteGUILeaves(2, cap: 2)   // two remoteGUI panes
        XCTAssertTrue(store.activateVideo(guiIDs[0]))
        XCTAssertTrue(store.activateVideo(guiIDs[1]))          // cap now saturated

        // Add terminal + claudeCode panes to the same canvas.
        store.addPane(kind: .terminal)
        let terminalID = store.workspace.canvas.allIDs().first { store.handle(for: $0)?.kind == .terminal }!
        store.addPane(kind: .claudeCode)
        let claudeID = store.workspace.canvas.allIDs().first { store.handle(for: $0)?.kind == .claudeCode }!

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

    /// Activating, then a structural mutation that does NOT touch the video panes (adding a
    /// terminal pane → reconcile), leaves the video activation state intact: reconcile never
    /// re-materializes or de-activates existing sessions, so the cap accounting is stable across
    /// reconciles. After the unrelated reconcile the gated pane is still gated.
    func testVideoActivationSurvivesUnrelatedReconcile() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]))

        // An unrelated structural mutation (new terminal pane) triggers reconcile but adds only a
        // terminal pane — the existing remoteGUI sessions (and their video state) are untouched.
        store.addPane(kind: .terminal)
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

        // Close the first live video pane (a non-last pane, so the canvas survives).
        store.closePane(ids[0])

        // Synchronously: it is gone from the registry and the invariant holds.
        XCTAssertNil(store.handle(for: ids[0]), "closed pane removed from the registry synchronously")
        XCTAssertEqual(Set(store.allSessions.map { $0.id }),
                       Set(store.workspace.canvas.allIDs()),
                       "registry keys == pane ids the instant closePane returns")

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

    // MARK: - BUG-D / F5: a superseded debounced save never wins the on-disk rename

    /// BUG-D / F5 — `saveImmediately()` (and a newer `scheduleSave`) must reliably win over an in-flight
    /// debounced write that has raced PAST its `Task.sleep`: `Task.cancel()` cannot stop a task already
    /// past its sleep, so the debounced path now re-checks `saveGeneration` AND writes the snapshot in
    /// ONE main-actor critical section (`await MainActor.run`) — the guard and the rename never release
    /// the actor between them, so a stale snapshot can never interleave and win the last rename.
    ///
    /// The pure-predicate assertions stay (they pin the SAME ``WorkspaceStore/isCurrentSaveGeneration(_:)``
    /// the production path consults), AND we strengthen it (F5): a SHORT debounce, so the parked task
    /// actually FIRES past its sleep WHILE a superseding `saveImmediately()` (then a newer
    /// `scheduleSave`) runs, then we assert the ON-DISK tree equals the NEWEST snapshot — not the stale
    /// one — by canvas pane count.
    func testSupersededDebouncedSaveIsSkippedByGenerationGuard() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-bugd-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let persistence = WorkspacePersistence(fileURL: tmp)
        let store = WorkspaceStore(
            restoring: nil,                       // default workspace: exactly 1 pane
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: persistence,
            saveDebounce: .milliseconds(40)       // SHORT — the parked task WILL fire during the test
        )
        XCTAssertEqual(store.workspace.canvas.itemCount, 1, "default workspace starts at one pane")

        // STALE snapshot: a mutation schedules a debounced save capturing the 2-pane canvas (gen0). The
        // task parks on its short 40ms sleep — its write has NOT run yet.
        store.addPane(kind: .terminal)
        let gen0 = store.saveGeneration
        let staleCount = store.workspace.canvas.itemCount   // 2 — must NEVER be the final on-disk shape
        XCTAssertEqual(staleCount, 2)
        XCTAssertTrue(store.isCurrentSaveGeneration(gen0), "the just-scheduled debounced write would write")

        // NEWEST snapshot: a second mutation (3 panes) then a synchronous `saveImmediately()`. The
        // immediate write bumps the generation and writes the 3-pane canvas NOW; the parked gen0 task is
        // now STALE. (saveImmediately cancels the pending task too, but the guard — not the cancel — is
        // what makes the result correct even if the task already raced past its sleep.)
        store.addPane(kind: .terminal)
        store.saveImmediately()
        let newestCount = store.workspace.canvas.itemCount  // 3 — the snapshot that must win on disk
        XCTAssertEqual(newestCount, 3)
        let genAfterImmediate = store.saveGeneration
        XCTAssertGreaterThan(genAfterImmediate, gen0, "saveImmediately bumped the generation past the debounced one")

        // The PURE generation-guard predicate (the production write path consults the very same one):
        // the stale gen0 is superseded; only the newest generation is current.
        XCTAssertFalse(store.isCurrentSaveGeneration(gen0),
                       "the superseded debounced write is no longer current — it will skip its write")
        XCTAssertTrue(store.isCurrentSaveGeneration(genAfterImmediate), "only the latest generation is current")

        // Let the parked gen0 debounced task actually WAKE past its 40ms sleep and reach its critical
        // section while we are superseded — well past the debounce so it genuinely fires (not merely
        // cancelled). Its main-actor guard finds gen0 stale and SKIPS the write, so the 3-pane newest
        // snapshot stays on disk; a stale 2-pane rename can never win.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "the file exists")
        let onDisk = persistence.load()
        XCTAssertEqual(onDisk.canvas.itemCount, newestCount,
                       "the ON-DISK tree is the NEWEST snapshot (3 panes), never the stale debounced one")
        XCTAssertNotEqual(onDisk.canvas.itemCount, staleCount,
                          "the superseded 2-pane debounced snapshot never won the rename")

        // A fresh mutation now schedules another short-debounce save (the NEWEST again, 4 panes); let it
        // fire to its completion. The on-disk tree follows the newest write, and the long-superseded
        // gen0 is still never current (the guard is monotone).
        store.addPane(kind: .terminal)
        let finalCount = store.workspace.canvas.itemCount   // 4
        XCTAssertGreaterThan(store.saveGeneration, genAfterImmediate, "a new mutation bumps the generation again")
        XCTAssertFalse(store.isCurrentSaveGeneration(gen0), "an old generation never becomes current again")

        try? await Task.sleep(for: .milliseconds(200))   // let the latest debounced save complete
        XCTAssertEqual(persistence.load().canvas.itemCount, finalCount,
                       "the latest debounced save wrote the newest 4-pane tree to disk")
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

        // Close ids[0] (a non-last pane → the canvas survives). Its teardown will park on the gate, so its
        // video stack is NOT yet released — `tearingDownVideo` holds its id.
        store.closePane(ids[0])
        XCTAssertNil(store.handle(for: ids[0]), "closed pane gone from the registry synchronously")

        // Same tick, open a replacement remoteGUI pane. It materializes idle.
        store.addPane(kind: .remoteGUI)
        let reopened = store.workspace.canvas.allIDs().first { $0 != ids[1] }!

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

    /// FIX #4: with a non-zero `videoTeardownSettle`, a closed video pane's cap slot stays HELD for the
    /// settle window PAST `teardown()`'s return — modelling the real SwiftUI dismantle →
    /// VideoWindowPipeline.deactivate() → detached session.stop() lag (the slot must not free until the
    /// UDP/VTDecompression/display-link stack is genuinely down). Here teardown returns immediately (no
    /// gate), but the settle keeps `tearingDownVideo` holding the slot so a same-tick reopen is gated
    /// until `quiesce()` drains past the settle. The DEFAULT settle is `.zero` (every other test), so
    /// this gate is opt-in and changes nothing on the existing paths.
    func testTeardownSettleHoldsSlotPastTeardownThenFrees() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 2, videoTeardownSettle: .milliseconds(80))
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]), "cap=2 saturated")

        // Close ids[0] (active) — teardown() returns immediately (no gate), but the settle holds its slot.
        store.closePane(ids[0])
        XCTAssertNil(store.handle(for: ids[0]), "closed pane gone from the registry synchronously")

        // Same tick, open a replacement. It must be GATED while the closing pane's slot is still held by
        // the settle (ids[1] live + ids[0] settling = cap of 2 occupied). Yield a few turns so teardown()
        // has returned but the settle sleep is still in flight.
        store.addPane(kind: .remoteGUI)
        let reopened = store.workspace.canvas.allIDs().first { $0 != ids[1] }!
        await Task.yield()
        XCTAssertFalse(store.activateVideo(reopened),
                       "reopen gated during the teardown settle — the closing pane's stack is still settling")

        // After quiesce() (which drains the teardown task INCLUDING its settle sleep), the slot frees.
        await store.quiesce()
        XCTAssertTrue(store.activateVideo(reopened),
                      "once the settle elapsed and the stack released, the reopened pane admits")
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([ids[1], reopened]), "exactly cap=2 live; the ceiling was never exceeded")
    }

    /// FIX #4 negative control: with the DEFAULT `.zero` settle, behaviour is byte-identical to today —
    /// a closed-active pane's slot frees as soon as `teardown()` returns (no settle hold). This pins
    /// that the gate is a strict opt-in and does not perturb the existing `.zero`-settle paths.
    func testZeroSettleFreesSlotImmediatelyAfterTeardown() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 2) // default settle = .zero
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        store.closePane(ids[0])
        store.addPane(kind: .remoteGUI)
        let reopened = store.workspace.canvas.allIDs().first { $0 != ids[1] }!
        await store.quiesce() // no settle sleep — teardown completes promptly
        XCTAssertTrue(store.activateVideo(reopened),
                      "with .zero settle the freed slot admits the reopened pane (today's behaviour)")
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
        store.addPane(kind: .remoteGUI)
        let reopened = store.workspace.canvas.allIDs().first { $0 != ids[1] }!
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

    /// VIDEO-UI-1 (audit): closing an active video pane bumps the promotion generation TWICE — once
    /// at CLOSE time (the slot is still counted via `tearingDownVideo`) AND again when the async
    /// teardown COMPLETES and the slot genuinely frees. The completion-site re-bump is the fix:
    /// without it, a same-tick gated reopen (refused at close because the slot was still counted)
    /// is never re-nudged when the slot actually frees, so it stays stuck on the "Video paused"
    /// placeholder until an unrelated event happens to nudge it.
    func testTeardownCompletionRebumpsPromotionGenerationWhenSlotFrees() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]), "gated while two are live")

        let before = store.videoPromotionGeneration
        store.closePane(ids[0])     // active video pane → close-time bump (slot STILL counted)
        let afterClose = store.videoPromotionGeneration
        XCTAssertEqual(afterClose, before + 1, "close-time nudge while the slot is still held by tearingDownVideo")

        await store.quiesce()       // teardown completes → slot frees → completion-site nudge (the fix)
        XCTAssertEqual(store.videoPromotionGeneration, afterClose + 1,
                       "teardown completion re-nudges so the gated pane re-attempts when the slot ACTUALLY frees")

        // The slot is genuinely free now — the previously-gated pane admits.
        XCTAssertTrue(store.activateVideo(ids[2]), "the freed slot admits the previously-gated pane")
    }

    // MARK: - BUG-A / F1: the display distinguishes unconfigured / free-slot / cap-saturated

    /// The PURE display decision (``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)``)
    /// distinguishes the three states (BUG-A + the F1 regression fix): an admitted pane is `.live`; an
    /// UNconfigured one shows the `.entryForm` (so the user can enter host/port); a CONFIGURED pane with
    /// a free slot ALSO shows the `.entryForm` (the form must stay until the reactive retry admits it —
    /// F1); only a CONFIGURED pane refused because the cap is SATURATED shows `.gated`.
    func testRemoteGUIDisplayResolveMatrix() {
        // Admitted always wins (live video), regardless of configured / slot state.
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: true, configured: true, hasFreeSlot: false), .live)
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: true, configured: false, hasFreeSlot: true), .live)

        // Not admitted + NOT configured ⇒ entry form, whether or not a slot is free (BUG-A: no host/port
        // yet, nothing to gate — never gate a merely-unconfigured pane).
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: false, hasFreeSlot: true), .entryForm)
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: false, hasFreeSlot: false), .entryForm)

        // Not admitted + configured + a slot IS FREE ⇒ STILL the entry form (F1): the form must not
        // vanish the instant the endpoint becomes valid; the reactive retry will admit it and flip it
        // to `.live`.
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: true, hasFreeSlot: true), .entryForm)

        // Not admitted + configured + NO free slot ⇒ the cap-saturated placeholder (the only `.gated`).
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: true, hasFreeSlot: false), .gated)
    }

    /// A fresh `.remoteGUI` pane created with no video endpoint (New Pane → Remote Window) has an
    /// UNconfigured ``RemoteWindowModel`` (`canOpen == false`), so even when the cap is saturated its
    /// display resolves to `.entryForm` — NOT `.gated`. This is the BUG-A invariant: an unconfigured pane
    /// can always reach its host/port form (it was previously stuck forever on the cap placeholder). Once
    /// it becomes configured the display depends on whether a slot is free (F1): free ⇒ still the form
    /// (the retry admits it), saturated ⇒ the gated placeholder.
    func testUnconfiguredRemoteGUIPaneIsNotCapGatedInDisplay() {
        // Build a live (production) remoteGUI session with no video endpoint, mirroring addPane.
        // The mux registry's factory is never invoked for a .remoteGUI pane (it has no terminal client).
        let registry = ConnectionRegistry { _, _ in
            throw AislopdeskTransportError.invalidState("remoteGUI pane never builds a terminal mux connection")
        }
        let session = WorkspaceStore.liveMakeSession(muxRegistry: registry)(PaneSpec(kind: .remoteGUI, title: "Remote window"))
        let live = session as! LivePaneSession
        XCTAssertNotNil(live.remoteWindow, "a remoteGUI session always has a RemoteWindowModel")
        XCTAssertFalse(live.remoteWindow!.canOpen, "a fresh unconfigured model cannot open (empty fields)")

        // Even un-admitted with NO free slot (cap saturated), the display is the entry form because the
        // model is not configured — never the cap placeholder.
        XCTAssertEqual(
            RemoteGUIDisplay.resolve(admitted: false, configured: live.remoteWindow!.canOpen, hasFreeSlot: false),
            .entryForm
        )

        // Dial in a valid window id (host/ports come from the app target now). The model becomes configured.
        live.remoteWindow!.windowID = "42"
        XCTAssertTrue(live.remoteWindow!.canOpen, "a valid window id ⇒ can open")

        // Configured + a slot still FREE ⇒ the form stays (F1 — the reactive retry will admit it). The
        // form does NOT vanish the instant the endpoint becomes valid.
        XCTAssertEqual(
            RemoteGUIDisplay.resolve(admitted: false, configured: live.remoteWindow!.canOpen, hasFreeSlot: true),
            .entryForm
        )

        // Configured + NO free slot ⇒ now correctly the cap placeholder (the cap is the real reason it
        // cannot decode).
        XCTAssertEqual(
            RemoteGUIDisplay.resolve(admitted: false, configured: live.remoteWindow!.canOpen, hasFreeSlot: false),
            .gated
        )
    }

    // MARK: - F1: hasFreeVideoSlot mirrors the activateVideo guard (the cap-vs-config discriminator)

    /// ``WorkspaceStore/hasFreeVideoSlot(for:)`` is the pure READ the view feeds into the display
    /// decision (F1) — it must agree EXACTLY with what an ``WorkspaceStore/activateVideo(_:)`` attempt
    /// this same tick would decide: free until the cap saturates with OTHER live panes, then not; and it
    /// self-excludes `id` so an already-active pane still sees its own slot as free.
    func testHasFreeVideoSlotMirrorsActivateGuard() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)

        // All idle ⇒ every pane sees a free slot.
        XCTAssertTrue(store.hasFreeVideoSlot(for: ids[0]))
        XCTAssertTrue(store.hasFreeVideoSlot(for: ids[2]))

        XCTAssertTrue(store.activateVideo(ids[0]))
        // One live (1 of 2): a free slot still exists for the others.
        XCTAssertTrue(store.hasFreeVideoSlot(for: ids[1]))

        XCTAssertTrue(store.activateVideo(ids[1]))
        // Cap saturated by two OTHER live panes ⇒ no free slot for the third (matches activateVideo's
        // refusal below).
        XCTAssertFalse(store.hasFreeVideoSlot(for: ids[2]))
        XCTAssertFalse(store.activateVideo(ids[2]), "the read agreed: activateVideo also refuses")

        // Self-exclusion: an ALREADY-active pane sees its own slot as free (it occupies it itself), so
        // the display never gates a pane that is in fact live.
        XCTAssertTrue(store.hasFreeVideoSlot(for: ids[0]), "self-exclusion — an active pane's own slot reads free")

        // Freeing a slot makes the read flip back to free for the gated pane.
        store.deactivateVideo(ids[0])
        XCTAssertTrue(store.hasFreeVideoSlot(for: ids[2]), "a freed slot reads as free again")
    }
}
