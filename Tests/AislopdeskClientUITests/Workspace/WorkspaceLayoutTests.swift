import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the pure responsive-breakpoint helpers in ``WorkspaceLayout`` (docs/22 §4, ITEM #6) and the
/// focus glue they cooperate with (BUG-F geometric-move-while-zoomed, BUG-K focus reclaim on focus
/// change).
///
/// All of it is synchronously testable with zero SwiftUI:
/// - the breakpoint functions are pure;
/// - the geometric-move contract is exercised through the ``WorkspaceStore`` `updateSolvedLayout`
///   seam (the only view→store geometry report) with the ``FakePaneSession`` factory — never a real
///   client / `HostServer`;
/// - ``PaneFocusCoordinator`` compiles + runs on macOS (its UIKit calls are `#if os(iOS)`; on macOS
///   `become`/`resign` claim synchronously through the injected ``FocusableInputHost`` fake), so the
///   tab-switch reclaim logic is unit-reachable here without a device.
@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    // MARK: - ITEM #6: the EXISTING detail-width breakpoint stays byte-for-byte (4 regressions)

    /// The original `isCompact(...:width:)` signature + the 460 detail threshold are load-bearing and
    /// must not drift (other call sites + the reconcile suite assert against them).
    func testDetailWidthBreakpointRegressions() {
        XCTAssertEqual(WorkspaceLayout.compactWidthThreshold, 460, "detail-width threshold pinned")
        // size-class compact → compact regardless of width.
        XCTAssertTrue(WorkspaceLayout.isCompact(horizontalSizeClassCompact: true, width: 1200))
        // wide detail → regular.
        XCTAssertFalse(WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, width: 1200))
        // macOS min-window detail (~500pt) → regular (below-ideal-sidebar still resolves the full tree).
        XCTAssertFalse(WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, width: 500))
        // genuinely phone-narrow detail → compact via the width fallback.
        XCTAssertTrue(WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, width: 400))
    }

    // MARK: - ITEM #6: the OUTER-WINDOW overload

    /// When a window width is supplied it is the geometry the breakpoint resolves against (NOT the
    /// detail width): a window above the window threshold → regular even if the detail column passed in
    /// is narrow (the mid-resize hazard the window reader exists to defuse).
    func testWindowWidthFallbackResolvesAgainstWindowThreshold() {
        XCTAssertEqual(WorkspaceLayout.compactWindowWidthThreshold, 680, "window threshold pinned (< 720 floor)")
        // A full-floor window (720) is REGULAR even though the detail GeometryReader momentarily reports
        // a sub-threshold 300pt mid-resize — the window width wins.
        XCTAssertFalse(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 300, windowWidth: 720),
            "window 720 (>= 680) resolves regular regardless of a transient narrow detail width",
        )
        // The window width, not the detail width, is the one compared: a wide detail can't rescue a
        // sub-threshold window.
        XCTAssertTrue(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 5000, windowWidth: 600),
            "window 600 (< 680) resolves compact even with a wide detail width",
        )
    }

    /// A window below the window threshold collapses to compact (a future sub-floor platform, or a
    /// transient pre-constraint frame).
    func testWindowWidthBelowWindowThresholdCollapses() {
        XCTAssertTrue(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 679, windowWidth: 679),
            "window just below 680 → compact",
        )
        XCTAssertFalse(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 680, windowWidth: 680),
            "window exactly at the threshold → regular (strict <)",
        )
    }

    /// F6 — with no window width (always on iOS; on macOS before the `NSWindow` reader fires) the
    /// breakpoint falls back to the DETAIL width compared against the DETAIL threshold (460), NOT the
    /// window threshold (680). Collapsing both into `(windowWidth ?? detailWidth) < 680` was the bug: it
    /// showed a one-frame compact carousel for the macOS floor window's ~500pt detail before the window
    /// reader fired, and silently moved the iPad-regular detail fallback from 460 to 680.
    func testWindowWidthNilFallsBackToDetailThreshold() {
        // The macOS floor window's ~500pt detail (before the NSWindow reader fires) must be REGULAR —
        // 500 >= 460, so no one-frame compact carousel.
        XCTAssertFalse(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 500, windowWidth: nil),
            "nil window → detail 500 (>= 460) resolves regular (no one-frame compact flash on macOS launch)",
        )
        // A genuinely phone-narrow detail still collapses via the 460 detail threshold.
        XCTAssertTrue(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 400, windowWidth: nil),
            "nil window → detail 400 (< 460) resolves compact",
        )
        // The nil-window fallback uses the DETAIL threshold (460), not the window threshold (680): a
        // detail between the two thresholds is REGULAR (it would wrongly be compact under the old
        // collapsed gate).
        XCTAssertFalse(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 600, windowWidth: nil),
            "nil window → detail 600 resolves against the 460 detail threshold ⇒ regular (not the 680 window one)",
        )
    }

    /// F6 — the window path and the detail-fallback path each use their OWN threshold: a known window
    /// width below 680 is compact; a known window width at/above 680 is regular EVEN with a narrow
    /// transient detail; and the two thresholds are not conflated.
    func testWindowAndDetailPathsUseDistinctThresholds() {
        // windowWidth 600 (< 680) → compact, regardless of detail.
        XCTAssertTrue(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 600, windowWidth: 600),
            "window 600 (< 680) → compact",
        )
        // windowWidth 720 (>= 680) with a transient narrow 300pt detail → regular (the window wins).
        XCTAssertFalse(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 300, windowWidth: 720),
            "window 720 (>= 680) → regular even with a transient narrow detail (300)",
        )
    }

    /// The size class stays the PRIMARY signal in the overload too: a compact size class forces compact
    /// regardless of however wide the window/detail is (the iOS path is unchanged).
    func testSizeClassStillPrimaryOverWindowWidth() {
        XCTAssertTrue(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: true, detailWidth: 5000, windowWidth: 5000),
            "size-class compact wins over an arbitrarily wide window",
        )
    }

    // MARK: - BUG-F: a zoomed pane's geometric move resolves against the on-screen single leaf

    /// Fixtures: a 3-leaf horizontal row on the single canvas, materialized through the fake seam.
    private func makeThreeLeafStore() -> (WorkspaceStore, [PaneID]) {
        let a0 = PaneID(), a1 = PaneID(), a2 = PaneID()
        let store = WorkspaceStore(
            restoring: Workspace.make(
                panes: [
                    (a0, PaneSpec(kind: .terminal, title: "a0")),
                    (a1, PaneSpec(kind: .terminal, title: "a1")),
                    (a2, PaneSpec(kind: .terminal, title: "a2")),
                ],
                focused: a1,
            ),
            makeSession: { FakePaneSession($0) },
        )
        return (store, [a0, a1, a2])
    }

    /// A 3-pane row laid out left→right. The pre-zoom multi-pane layout makes `move(.left)` from the
    /// middle pane land on the left pane — the regular-tree behaviour.
    func testDirectionalMoveUsesReportedMultiPaneLayout() {
        let (store, ids) = makeThreeLeafStore()
        store.updateSolvedLayout(SolvedLayout(
            frames: [
                ids[0]: CGRect(x: 0, y: 0, width: 100, height: 100),
                ids[1]: CGRect(x: 100, y: 0, width: 100, height: 100),
                ids[2]: CGRect(x: 200, y: 0, width: 100, height: 100),
            ],
        ))
        XCTAssertEqual(store.focusedPane, ids[1], "focused on the middle pane")
        store.move(.left)
        XCTAssertEqual(store.focusedPane, ids[0], "move(.left) lands on the left neighbour")
    }

    /// BUG-F: while a pane is ZOOMED the view reports a SINGLE-LEAF layout (the zoomed pane fills the
    /// rect). A directional move then has no neighbour on screen and must NOT jump to an off-screen
    /// pane that only exists in the stale pre-zoom rects — focus stays put.
    func testZoomedSingleLeafLayoutSuppressesDirectionalMoveToOffscreenPane() {
        let (store, ids) = makeThreeLeafStore()
        // Pre-zoom multi-pane layout (what the regular tree reported before zoom).
        store.updateSolvedLayout(SolvedLayout(
            frames: [
                ids[0]: CGRect(x: 0, y: 0, width: 100, height: 100),
                ids[1]: CGRect(x: 100, y: 0, width: 100, height: 100),
                ids[2]: CGRect(x: 200, y: 0, width: 100, height: 100),
            ],
        ))
        // Zoom the focused (middle) pane. The FIX has PaneTreeView's zoomed branch report a single-leaf
        // layout; simulate that report through the same store seam the view uses.
        store.toggleZoom()
        XCTAssertEqual(store.workspace.maximizedPane, ids[1], "middle pane is zoomed")
        store.updateSolvedLayout(SolvedLayout(
            frames: [ids[1]: CGRect(x: 0, y: 0, width: 300, height: 100)],
        ))

        // A directional move finds no neighbour in the single-leaf layout → focus is unchanged (no jump
        // to the off-screen left/right pane the stale multi-pane rects would have offered).
        store.move(.left)
        XCTAssertEqual(store.focusedPane, ids[1], "move(.left) while zoomed does not jump off-screen")
        store.move(.right)
        XCTAssertEqual(store.focusedPane, ids[1], "move(.right) while zoomed does not jump off-screen")
    }

    /// BUG-F downstream: closing the zoomed pane refocuses a TREE neighbour (pre-order), not a stale
    /// geometric rect. With a single-leaf layout reported, `neighbourForRefocus` falls through to the
    /// tree's pre-order successor/predecessor — a real surviving pane.
    func testCloseZoomedPaneRefocusesSurvivingTreeNeighbour() async throws {
        let (store, ids) = makeThreeLeafStore()
        store.toggleZoom() // zoom the middle pane (ids[1])
        store.updateSolvedLayout(SolvedLayout(
            frames: [ids[1]: CGRect(x: 0, y: 0, width: 300, height: 100)],
        ))
        store.closePane(ids[1])
        let survivors = store.workspace.canvas.allIDs()
        XCTAssertEqual(survivors.count, 2, "closing one of three leaves leaves two")
        XCTAssertNotNil(store.focusedPane)
        XCTAssertTrue(
            try survivors.contains(XCTUnwrap(store.focusedPane)),
            "refocus lands on a surviving pane, not the closed/zoomed one",
        )
        await store.quiesce()
    }

    // MARK: - BUG-K: a focus change forces the newly-focused terminal to re-claim first responder

    /// A minimal fake first-responder host so the coordinator's claim/resign logic is assertable on
    /// macOS (the real UIKit path is `#if os(iOS)`; on macOS `become`/`resign` run synchronously).
    private final class FakeHost: PaneFocusCoordinator.FocusableInputHost {
        private(set) var becomeCount = 0
        private(set) var resignCount = 0
        var isFirstResponder = false
        @discardableResult
        func resignFocus() -> Bool { resignCount += 1
            isFirstResponder = false
            return true
        }

        @discardableResult
        func becomeFocus() -> Bool { becomeCount += 1
            isFirstResponder = true
            return true
        }
    }

    /// `reassertFocus(_:)` claims first responder for the target even when the coordinator already
    /// records it as focused — the case `focus(_:)`'s caller-side guard would skip on a no-op re-focus.
    func testReassertFocusClaimsEvenWhenAlreadyBookkeptFocused() {
        let coordinator = PaneFocusCoordinator()
        let pane = PaneID()
        let host = FakeHost()
        coordinator.register(host, for: pane)

        // First focus claims once.
        coordinator.focus(pane)
        XCTAssertEqual(host.becomeCount, 1, "initial focus claimed first responder")
        XCTAssertEqual(coordinator.focusedPane, pane)

        // A guarded re-focus to the SAME pane is what the store's same-pane path would do — but it
        // skips (focusedPane == focused). `reassertFocus` instead claims AGAIN despite the matching
        // bookkeeping (BUG-K).
        coordinator.reassertFocus(pane)
        XCTAssertEqual(host.becomeCount, 2, "reassertFocus re-claims even though pane was already focused")
        XCTAssertEqual(coordinator.focusedPane, pane)
    }

    /// End-to-end through the store seam: focusing another pane whose terminal host is registered
    /// re-claims first responder and the coordinator's intent follows the newly-focused pane (the
    /// BUG-K race shape). Two panes on the single canvas; we register hosts for both and drive focus.
    func testFocusChangeReassertsFocusForNewlyFocusedHost() {
        let pA = PaneID(), pB = PaneID()
        let store = WorkspaceStore(
            restoring: Workspace.make(
                panes: [
                    (pA, PaneSpec(kind: .terminal, title: "A")),
                    (pB, PaneSpec(kind: .terminal, title: "B")),
                ],
                focused: pA,
            ),
            makeSession: { FakePaneSession($0) },
        )
        let hostA = FakeHost(), hostB = FakeHost()
        store.focusCoordinator.register(hostA, for: pA)
        store.focusCoordinator.register(hostB, for: pB)

        // The init reconcile already reasserted focus to pane A (first sync = "focus changed" from
        // nil). Snapshot B's claim count, then move focus to B.
        let bBefore = hostB.becomeCount
        store.focus(pB)
        XCTAssertEqual(store.focusedPane, pB)
        XCTAssertGreaterThan(hostB.becomeCount, bBefore, "focusing pane B re-claims its terminal (BUG-K)")
        XCTAssertEqual(store.focusCoordinator.focusedPane, pB, "coordinator intent follows the newly-focused pane")
    }

    // MARK: - Group arithmetic (the single-canvas replacement for the retired tab arithmetic)

    /// The pure group ops mirror what the old tab arithmetic did (add → rename → reorder → remove),
    /// each returning a fresh ``Workspace`` and leaving the canvas's pane set untouched (a group is
    /// metadata — removing one ungroups its members rather than closing any pane).
    func testGroupArithmeticAddRenameReorderRemove() {
        let p0 = PaneID(), p1 = PaneID()
        let base = Workspace.make(
            panes: [
                (p0, PaneSpec(kind: .terminal, title: "p0")),
                (p1, PaneSpec(kind: .terminal, title: "p1")),
            ],
            focused: p0,
        )

        // Add two groups; each returns the minted id.
        let (afterFirst, g0) = base.addingGroup(name: "Left")
        let (afterSecond, g1) = afterFirst.addingGroup(name: "Right")
        XCTAssertEqual(afterSecond.groups.map(\.id), [g0, g1], "two groups appended in order")
        XCTAssertEqual(afterSecond.group(g0)?.name, "Left")

        // Rename the first group.
        let renamed = afterSecond.renamingGroup(g0, to: "Primary")
        XCTAssertEqual(renamed.group(g0)?.name, "Primary", "rename updates the group's name in place")

        // Assign a pane into a group, then reorder the groups (the old "move tab" equivalent).
        let assigned = renamed.assigning(pane: p0, toGroup: g0)
        XCTAssertEqual(assigned.group(ofPane: p0)?.id, g0, "pane p0 now belongs to the first group")
        let reordered = assigned.movingGroup(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(reordered.groups.map(\.id), [g1, g0], "movingGroup reorders the sidebar list")

        // Removing a group ungroups its members but never drops a pane (the old "close tab" never
        // closed panes either — there is no destructive analogue).
        let removed = reordered.removingGroup(g0)
        XCTAssertNil(removed.group(g0), "removed group is gone")
        XCTAssertNil(removed.group(ofPane: p0), "its member pane survives as ungrouped")
        XCTAssertEqual(removed.canvas.allIDs().count, 2, "no pane was closed by removing a group")
    }
}
