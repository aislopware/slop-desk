// TerminationDrainTests — pins the QUIT-DRAIN fix (orphaned-session leak): app quit previously never
// drained the in-flight pane teardowns (`WorkspaceStore.quiesce()` had ZERO call sites), so a ⌘W-then-⌘Q
// killed the process before a just-closed busy pane's bye/channelClose reached the wire — the host
// soft-detached the session into `DetachedSessionStore` (default TTL: NEVER) with no owning client left.
// The fix is `SlopDeskAppTerminationDelegate` (`.terminateLater` + reply after a BOUNDED drain); the
// bounded race itself is the pure, headlessly-pinnable piece — `TerminationDrain.drain(timeout:operation:)`.
//
// Three pins:
//   1. a completing drain returns promptly (never eats the full timeout),
//   2. a WEDGED drain is bounded by the timeout (quit can never hang),
//   3. the drain actually awaits a real store's in-flight teardown (`quiesce()` end-to-end over a
//      slow-teardown fake session — the exact ⌘W-then-⌘Q shape).
//
// The remaining glue (`applicationShouldTerminate` → `.terminateLater` → `reply`) is AppKit-only and is
// NOT driven here (no `NSApplication` in unit tests — hang-safety); its manual verification steps are in
// the delegate's doc comment / the fix report.

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class TerminationDrainTests: XCTestCase {
    /// 1. A drain whose operation completes returns as soon as it does — it must NOT sit out the full
    /// timeout (a clean quit stays instant).
    func testDrainReturnsAsSoonAsOperationCompletes() async {
        var operationRan = false
        let clock = ContinuousClock()
        let start = clock.now
        await TerminationDrain.drain(timeout: .seconds(10)) { operationRan = true }
        let elapsed = clock.now - start
        XCTAssertTrue(operationRan, "the drain ran the operation")
        XCTAssertLessThan(elapsed, .seconds(5), "a completed drain must return long before the timeout")
    }

    /// 2. A WEDGED operation (never finishes) is bounded by the timeout — quit must never hang on a
    /// stuck teardown. The losing operation task keeps running in the background by design.
    func testDrainIsBoundedByTimeoutWhenOperationHangs() async {
        var operationFinished = false
        let clock = ContinuousClock()
        let start = clock.now
        await TerminationDrain.drain(timeout: .milliseconds(100)) {
            // A teardown wedged forever (e.g. a peer that never acks the bye).
            try? await Task.sleep(for: .seconds(60))
            operationFinished = true
        }
        let elapsed = clock.now - start
        XCTAssertFalse(operationFinished, "the wedged operation did not finish — the timeout won the race")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(100), "the drain waited out the budget")
        XCTAssertLessThan(elapsed, .seconds(10), "the drain is bounded — quit never hangs")
    }

    /// 3. End-to-end over a real tree store: close a pane whose teardown is SLOW (the busy-pane bye in
    /// flight), then drain `quiesce()` — the teardown must have COMPLETED when the drain returns (the
    /// bye reached the wire before the process would die). This is the ⌘W-then-⌘Q shape.
    func testDrainAwaitsInFlightPaneTeardownViaQuiesce() async throws {
        var fakes: [SlowTeardownPaneSession] = []
        let store = WorkspaceStore(liveModel: .tree, makeSession: { spec in
            let fake = SlowTeardownPaneSession(spec, delay: .milliseconds(100))
            fakes.append(fake)
            return fake
        })
        store.reconcileTree()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        XCTAssertEqual(fakes.count, 2, "two live panes materialized")
        let closing = try XCTUnwrap(store.tree.allPaneIDs().last)
        let closingFake = try XCTUnwrap(fakes.first { $0.id == closing })

        store.closePaneTree(closing) // registry key dropped synchronously; teardown runs in background
        XCTAssertFalse(closingFake.teardownCompleted, "the slow teardown is still in flight at close time")

        await TerminationDrain.drain(timeout: .seconds(10)) { await store.quiesce() }
        XCTAssertTrue(
            closingFake.teardownCompleted,
            "quit's drain awaited the in-flight teardown — the bye reaches the wire before the process dies",
        )
    }
}

/// A `PaneSessionHandle` fake whose `teardown()` takes real time — the in-flight bye/channelClose of a
/// just-closed busy pane. Mirrors `MountTestPaneSession` (same target) plus the slow, completion-flagged
/// teardown the drain pins ride on.
@MainActor
private final class SlowTeardownPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable,
    PaneSessionIDAdopting
{
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false
    /// Set only AFTER the slow teardown finished — the "bye reached the wire" marker.
    private(set) var teardownCompleted = false
    private let delay: Duration

    init(_ spec: PaneSpec, delay: Duration) {
        id = PaneID()
        kind = spec.kind
        self.delay = delay
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind.isVideo { isVideoActive = active } }
    // Sync witnesses legally satisfy the `async` protocol requirements (avoids `async_without_await`).
    func pause() {}
    func resume() {}
    func teardown() async {
        try? await Task.sleep(for: delay)
        teardownCompleted = true
    }
}
