import XCTest
@testable import AislopdeskClientUI

/// Tests for ``PaneFocusCoordinator`` registration semantics — specifically the R13 #8 make-before-
/// dismantle race: a host that dismantles must unregister BY IDENTITY so it cannot clobber a NEW host
/// that already re-registered under the same paneID. The coordinator is cross-platform (it compiles on
/// macOS, where there is no UIKit first-responder model), so this is unit-testable without a device.
@MainActor
final class PaneFocusCoordinatorTests: XCTestCase {

    private final class FakeHost: PaneFocusCoordinator.FocusableInputHost {
        private(set) var became = false
        func resignFocus() -> Bool { true }
        func becomeFocus() -> Bool { became = true; return true }
    }

    /// Identity-unregister (the fix): host A dismantles by IDENTITY AFTER host B re-registered under the
    /// same paneID — B must remain the live, focusable host (not be clobbered by A's teardown).
    func testUnregisterByHostIdentityPreservesReregisteredHost() {
        let coord = PaneFocusCoordinator()
        let id = PaneID()
        let a = FakeHost(), b = FakeHost()
        coord.register(a, for: id)
        coord.register(b, for: id)        // make-before-dismantle: B replaces A under the same paneID
        coord.unregister(host: a)         // A's dismantle — by IDENTITY, must NOT drop B
        coord.focus(id)
        XCTAssertTrue(b.became, "the live re-registered host B is still focusable")
        XCTAssertFalse(a.became, "the dismantled host A never focuses")
    }

    /// Contrast — the OLD by-paneID unregister drops WHATEVER is registered, clobbering the live B. This
    /// documents exactly why `dismantleUIView` must unregister by identity, not by paneID (R13 #8).
    func testUnregisterByPaneIDClobbersReregisteredHost() {
        let coord = PaneFocusCoordinator()
        let id = PaneID()
        let a = FakeHost(), b = FakeHost()
        coord.register(a, for: id)
        coord.register(b, for: id)
        coord.unregister(id)              // by-paneID drops the live B too
        coord.focus(id)
        XCTAssertFalse(b.became, "by-paneID unregister wrongly dropped the live host (the R13 #8 bug)")
    }
}
