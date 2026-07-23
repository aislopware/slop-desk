// BackgroundPointerPolicyTests — pins the background-interaction gate decisions (the satellite
// window's pointer-while-not-key contract). The AppKit view consults exactly these two functions, so
// a regression here (e.g. dropping the key-window check from `backgroundClick`) is a real behavior
// break: a click on the ALREADY-KEY desktop window would stop activating the workspace pane.

import XCTest
@testable import SlopDeskVideoClient

final class BackgroundPointerPolicyTests: XCTestCase {
    // MARK: forwardsPointer

    /// The canvas rule survives verbatim: a non-active pane with no background-pointer grant ignores
    /// hover — it must never inject a stray remote mouse-move (you click it first).
    func testInactiveCanvasPaneStillIgnoresHover() {
        XCTAssertFalse(BackgroundPointerPolicy.forwardsPointer(isActive: false, backgroundPointer: false))
    }

    /// The active pane forwards hover exactly as before, with or without the grant.
    func testActivePaneForwardsHoverRegardlessOfGrant() {
        XCTAssertTrue(BackgroundPointerPolicy.forwardsPointer(isActive: true, backgroundPointer: false))
        XCTAssertTrue(BackgroundPointerPolicy.forwardsPointer(isActive: true, backgroundPointer: true))
    }

    /// The new case: a background-pointer satellite forwards hover while NOT active (its window is
    /// not key) — the whole point of background interaction.
    func testBackgroundPointerSatelliteForwardsHoverWhileInactive() {
        XCTAssertTrue(BackgroundPointerPolicy.forwardsPointer(isActive: false, backgroundPointer: true))
    }

    // MARK: backgroundClick

    /// A click on a NOT-key background-pointer surface is a background click: forwarded with the
    /// window left un-activated and `onActivate` skipped.
    func testClickOnNotKeyBackgroundPointerWindowIsBackground() {
        XCTAssertTrue(BackgroundPointerPolicy.backgroundClick(backgroundPointer: true, windowIsKey: false))
    }

    /// LOAD-BEARING: the KEY window always takes the normal activate path — background mode changes
    /// only the not-key case. Without this, clicking the focused desktop window would stop
    /// activating the workspace pane (and stop raising the host window on refocus).
    func testClickOnKeyWindowIsNeverBackground() {
        XCTAssertFalse(BackgroundPointerPolicy.backgroundClick(backgroundPointer: true, windowIsKey: true))
    }

    /// Without the grant (canvas pane / setting OFF) a click is never a background click, key or not
    /// — click-to-activate stands everywhere else.
    func testClickWithoutGrantIsNeverBackground() {
        XCTAssertFalse(BackgroundPointerPolicy.backgroundClick(backgroundPointer: false, windowIsKey: false))
        XCTAssertFalse(BackgroundPointerPolicy.backgroundClick(backgroundPointer: false, windowIsKey: true))
    }
}
