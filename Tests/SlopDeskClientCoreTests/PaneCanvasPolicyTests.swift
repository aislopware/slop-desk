// PaneCanvasPolicyTests — the canvas spine's remaining decisions, once they were reachable.
//
// `PaneFocusPolicy` already has two suites of its own (`PaneFocusStealGuardTests`,
// `PaneFocusCornerGateTests`, plus the composed `PaneSwitcherRecedeTests`). What is pinned here is
// everything else the compositor decided inside a `some View`: WHICH tabs stay mounted, WHAT a
// destination means to the local overlay, WHICH cursor a clamped seam asks for, and WHY the canvas
// is empty.
//
// The mounting rule is the load-bearing one. Keep-all-mounted is the invariant that keeps a
// libghostty-vt surface alive across a tab AND a session switch, and it is spelled as a filter over
// three inputs — so an intersection that drops the active session, or a retention set that goes
// stale, is a teardown of every pane on screen.

import CoreGraphics
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

final class PaneCanvasMountingTests: XCTestCase {
    private func session(name: String, tabs: Int) -> Session {
        var specs: [PaneID: PaneSpec] = [:]
        let built = (0..<tabs).map { _ -> Tab in
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: "")
            return Tab(root: .leaf(pane), activePane: pane)
        }
        return Session(name: name, tabs: built, specs: specs)
    }

    /// EVERY tab of every RETAINED session mounts, in session-then-tab order — that ordering is what
    /// keeps the compositor's `ForEach` stable, and stability is what keeps the surfaces alive.
    func testEveryTabOfEveryRetainedSessionMounts() {
        let a = session(name: "a", tabs: 2)
        let b = session(name: "b", tabs: 1)
        let c = session(name: "c", tabs: 3)

        let mounted = PaneCanvasMounting.mountedTabs(
            sessions: [a, b, c], retained: [a.id, c.id], activeID: a.id,
        )

        XCTAssertEqual(mounted.map(\.id), a.tabs.map(\.id) + c.tabs.map(\.id))
    }

    /// THE FIRST-SWITCH CASE: the active session is mounted even when the retention set is still
    /// empty (it is, right after launch). Without this the very first frame would mount nothing.
    func testTheActiveSessionMountsEvenWithAnEmptyRetentionSet() {
        let a = session(name: "a", tabs: 2)
        XCTAssertEqual(
            PaneCanvasMounting.mountedTabs(sessions: [a], retained: [], activeID: a.id).count, 2,
        )
    }

    /// A retained id whose session has since CLOSED is dropped by the `sessions` intersection rather
    /// than resurrecting a tab that no longer exists.
    func testAStaleRetainedIDIsDropped() {
        let a = session(name: "a", tabs: 1)
        let closed = session(name: "gone", tabs: 4)

        let mounted = PaneCanvasMounting.mountedTabs(
            sessions: [a], retained: [closed.id, a.id], activeID: a.id,
        )
        XCTAssertEqual(mounted.map(\.id), a.tabs.map(\.id))
    }

    /// A session that is neither active nor retained is unmounted — the retention set is a ceiling,
    /// not a suggestion, or every session ever opened would keep its decode stacks running.
    func testAnUnretainedSessionDoesNotMount() {
        let a = session(name: "a", tabs: 1)
        let b = session(name: "b", tabs: 1)

        XCTAssertEqual(
            PaneCanvasMounting.mountedTabs(sessions: [a, b], retained: [], activeID: a.id).map(\.id),
            a.tabs.map(\.id),
        )
    }
}

final class PaneCanvasMetricsTests: XCTestCase {
    /// The stacking band: panes at the base, dividers above them, the move-handle / drag overlay on
    /// top. The ORDER is the claim — a divider that stacks over the drag overlay eats the drop.
    func testTheZBandStacksDragChromeOverDividersOverPanes() {
        XCTAssertGreaterThan(PaneCanvasMetrics.dividerZ, 0)
        XCTAssertGreaterThan(PaneCanvasMetrics.moveZ, PaneCanvasMetrics.dividerZ)
    }

    /// The local overlay previews only what will land in THIS canvas. Every external destination
    /// reads `.none`, so a drag heading for the sidebar or out of the window never draws an in-canvas
    /// promise it will not keep.
    func testOnlyACanvasDestinationCarriesAZone() {
        let target = PaneID()

        XCTAssertEqual(PaneCanvasMetrics.canvasZone(of: .canvas(.swap(target: target))), .swap(target: target))
        XCTAssertEqual(PaneCanvasMetrics.canvasZone(of: .canvas(.none)), .none)
        XCTAssertEqual(PaneCanvasMetrics.canvasZone(of: .sidebarRow(target)), .none)
        XCTAssertEqual(PaneCanvasMetrics.canvasZone(of: .newTab), .none)
        XCTAssertEqual(PaneCanvasMetrics.canvasZone(of: .tearOff), .none)
        XCTAssertEqual(PaneCanvasMetrics.canvasZone(of: .none), .none)
    }

    /// TRUTH AT THE CLAMP: a seam whose neighbour is already at the minimum-weight floor asks for the
    /// one-way arrow for the only direction the drag still has. The glyph reads the same pair weights
    /// the gesture clamps on, so the two can never disagree.
    func testTheResizeCursorNamesTheDirectionsTheDragStillHas() {
        XCTAssertEqual(
            PaneCanvasMetrics.resizePointer(axis: .horizontal, toLeading: true, toTrailing: true),
            .columnResize(toLeading: true, toTrailing: true),
        )
        XCTAssertEqual(
            PaneCanvasMetrics.resizePointer(axis: .horizontal, toLeading: false, toTrailing: true),
            .columnResize(toLeading: false, toTrailing: true),
            "the leading neighbour is at the floor — only one way left",
        )
        XCTAssertEqual(
            PaneCanvasMetrics.resizePointer(axis: .vertical, toLeading: true, toTrailing: false),
            .rowResize(toUp: true, toDown: false),
            "a vertical split's seam moves UP and DOWN, not left and right",
        )
    }
}

final class PaneEmptyCauseTests: XCTestCase {
    /// The four sentences an empty canvas can say, and each is a different next action: mint a tab,
    /// wait (the supervisor is redialing), correct the host, or connect for the first time.
    func testEachConnectionStateNamesItsOwnCause() {
        XCTAssertEqual(PaneEmptyCause.resolve(status: .connected, host: "h"), .noTabs)
        XCTAssertEqual(
            PaneEmptyCause.resolve(status: .reconnecting(attempt: 2, nextRetry: nil), host: "mac-studio"),
            .linkDown(host: "mac-studio"),
            "the caption names the host being re-dialed",
        )
        XCTAssertEqual(PaneEmptyCause.resolve(status: .disconnected, host: "h"), .neverConnected)
        XCTAssertEqual(
            PaneEmptyCause.resolve(status: .connecting, host: "h"), .neverConnected,
            "a FIRST dial reads not-connected — there is nothing to say it is coming back to",
        )
        XCTAssertEqual(PaneEmptyCause.resolve(status: .unreachable, host: "h"), .neverConnected)
    }

    /// A failed connect carries the REAL reason, run through the same friendly-failure pass the
    /// connection surfaces use — so a wrong port reads as its own mistake instead of as the generic
    /// not-connected copy.
    func testAFailedConnectCarriesTheFriendlyReason() {
        XCTAssertEqual(
            PaneEmptyCause.resolve(status: .failed("boom"), host: "h"),
            .connectFailed(reason: ConnectionPresenter.friendlyFailure("boom")),
        )
        guard case let .connectFailed(reason) = PaneEmptyCause.resolve(
            status: .failed("POSIXErrorCode(rawValue: 61): Connection refused"), host: "h",
        ) else {
            XCTFail("a failed connect must resolve to `.connectFailed`")
            return
        }
        XCTAssertFalse(reason.contains("POSIXErrorCode"), "the raw errno spelling never reaches the caption")
    }
}
