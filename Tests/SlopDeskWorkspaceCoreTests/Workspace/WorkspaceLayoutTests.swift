import CoreGraphics
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the ``WorkspaceLayout`` breakpoint CROSSING (the rule itself — both thresholds and why each
/// geometry is read against its own — is `slopdesk_workspace::responsive`) and the focus glue it
/// cooperates with (BUG-F geometric-move-while-zoomed, BUG-K focus reclaim on focus change).
///
/// All of it is synchronously testable with zero SwiftUI:
/// - the breakpoint is one door call whose only near-side decision is `windowWidth != nil`;
/// - the geometric-move contract is exercised through the ``WorkspaceStore`` `updateSolvedLayout`
///   seam (the only view→store geometry report) with the ``FakePaneSession`` factory — never a real
///   client / `HostServer`;
/// - ``PaneFocusCoordinator`` compiles + runs on macOS (its UIKit calls are `#if os(iOS)`; on macOS
///   `become`/`resign` claim synchronously through the injected ``FocusableInputHost`` fake), so the
///   tab-switch reclaim logic is unit-reachable here without a device.
@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    // MARK: - The breakpoint crossing

    /// An ABSENT window is not a window of the detail's width — the one thing this side can get wrong,
    /// since `nil` crosses as a `(0, false)` pair rather than as a number. A 500pt detail with no window
    /// yet is REGULAR (the macOS floor before the `NSWindow` reader fires); the same detail inside a
    /// 600pt window is compact.
    func testAbsentWindowIsNotAWindowOfTheDetailWidth() {
        XCTAssertFalse(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 500, windowWidth: nil),
            "nil window → the detail decides, against the detail threshold (no one-frame compact flash)",
        )
        XCTAssertTrue(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 500, windowWidth: 600),
            "a sub-floor window is compact even though the same detail resolved regular without one",
        )
        XCTAssertFalse(
            WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, detailWidth: 300, windowWidth: 720),
            "the floor window is regular regardless of a transient narrow detail",
        )
    }

    /// The size class stays the PRIMARY signal across the boundary: it forces compact regardless of
    /// however wide the window/detail is (the iOS path).
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
