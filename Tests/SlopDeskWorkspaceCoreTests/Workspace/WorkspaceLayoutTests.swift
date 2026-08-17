import CoreGraphics
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

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
    /// BUG-K race shape). Two leaves in one tab; we register hosts for both and drive focus.
    func testFocusChangeReassertsFocusForNewlyFocusedHost() throws {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            makeSession: { seed in FakePaneSession(seed.spec) },
        )
        store.attachLoopbackWorkspaceDocument()
        let pA = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let pB = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != pA }, "the split minted a second leaf")

        let hostA = FakeHost(), hostB = FakeHost()
        store.focusCoordinator.register(hostA, for: pA)
        store.focusCoordinator.register(hostB, for: pB)

        // Snapshot B's claim count, then move focus back and forth so the LAST move lands on B.
        store.focusPaneTree(pA)
        let bBefore = hostB.becomeCount
        store.focusPaneTree(pB)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, pB)
        XCTAssertGreaterThan(hostB.becomeCount, bBefore, "focusing pane B re-claims its terminal (BUG-K)")
        XCTAssertEqual(store.focusCoordinator.focusedPane, pB, "coordinator intent follows the newly-focused pane")
    }
}
