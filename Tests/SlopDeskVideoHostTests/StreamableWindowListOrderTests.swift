import SlopDeskVideoHost
import XCTest

/// Pins the `windowList` reply arrangement now that the reply is built from the FULL enumeration
/// (the reply is the client's authority for BOTH the in-pane picker and `WindowRebind`'s reconnect
/// revalidation — omitting minimized windows made the client's revalidation close a pane whose
/// hello the host was about to rescue-and-accept): on-screen windows first so the reply cap can
/// only ever crowd out the off-screen tail, and untitled off-screen entries dropped (phantom
/// enumeration junk has no title; a real minimized window keeps its).
final class StreamableWindowListOrderTests: XCTestCase {
    private struct StubWindow: Equatable {
        let id: Int
        let onScreen: Bool
        let title: String
    }

    private func arrange(_ windows: [StubWindow]) -> [StubWindow] {
        StreamableWindowListOrder.arrange(windows, isOnScreen: \.onScreen, title: \.title)
    }

    /// On-screen windows lead the reply — in their original relative order — and titled off-screen
    /// windows follow, also order-preserved, so a downstream cap evicts off-screen entries first.
    func testOnScreenLeadOffScreenTailBothOrderPreserved() {
        let a = StubWindow(id: 1, onScreen: false, title: "minimized editor")
        let b = StubWindow(id: 2, onScreen: true, title: "front")
        let c = StubWindow(id: 3, onScreen: false, title: "other-space browser")
        let d = StubWindow(id: 4, onScreen: true, title: "")
        XCTAssertEqual(arrange([a, b, c, d]), [b, d, a, c])
    }

    /// Untitled OFF-screen entries are phantom junk and are dropped; an untitled ON-screen window
    /// (real apps show untitled windows) stays.
    func testUntitledOffScreenDroppedUntitledOnScreenKept() {
        let onScreenUntitled = StubWindow(id: 1, onScreen: true, title: "")
        let offScreenUntitled = StubWindow(id: 2, onScreen: false, title: "")
        XCTAssertEqual(arrange([offScreenUntitled, onScreenUntitled]), [onScreenUntitled])
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(arrange([]), [])
    }
}
