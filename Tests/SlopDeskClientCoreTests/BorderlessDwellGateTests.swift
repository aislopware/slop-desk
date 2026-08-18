#if os(macOS)
import XCTest
@testable import SlopDeskClientCore

/// The crossing for the dwell policy behind borderless-fullscreen's local-menu-bar reveal (the
/// Parallels model). The gesture itself is pinned in `slopdesk_workspace::chrome`; what is checked
/// here is that the gate survives the round trip it makes on every pointer move — phase AND clock —
/// and that the phase arrives in the vocabulary the AppKit layer switches over when it maps onto
/// `NSApp.presentationOptions`.
final class BorderlessDwellGateTests: XCTestCase {
    /// A bare touch at the top edge must NOT reveal — it arms, and the reveal waits out the dwell.
    /// This is the whole point: that first touch belongs to the REMOTE menu bar.
    func testTopEdgeTouchArmsButDoesNotReveal() {
        var g = BorderlessDwellGate()
        XCTAssertEqual(g.update(pointerYFromTop: 0, now: 100), .arming(since: 100))
        XCTAssertFalse(g.isRevealed)
        XCTAssertEqual(
            g.armingDeadline,
            100 + g.dwellSeconds,
            "the AppKit layer schedules its dwell timer here",
        )
    }

    /// The clock crosses back intact on every fold: a dwell that restarted on each pointer move
    /// could never finish, and a held pointer would sit at the edge forever.
    func testTheDwellClockSurvivesEveryFold() {
        var g = BorderlessDwellGate(dwellSeconds: 0.5, revealZonePoints: 2, concealZonePoints: 36)
        g.update(pointerYFromTop: 0, now: 100)
        XCTAssertEqual(g.update(pointerYFromTop: 1, now: 100.4), .arming(since: 100), "still inside the dwell")
        XCTAssertEqual(g.update(pointerYFromTop: 1, now: 100.5), .revealed)
        XCTAssertTrue(g.isRevealed)
        XCTAssertNil(g.armingDeadline, "no timer once revealed")
    }

    /// The three distances the resting gate is built with come from the door, so the AppKit layer
    /// and the policy cannot disagree about what "pressed against the edge" means.
    func testTheRestingGateCarriesTheDecisionsOwnDistances() {
        let g = BorderlessDwellGate()
        XCTAssertGreaterThan(g.dwellSeconds, 0, "a passing touch has to be able to lose the race")
        XCTAssertGreaterThan(
            g.concealZonePoints,
            g.revealZonePoints,
            "hysteresis: the revealed bar must not flicker shut while it is being used",
        )
    }

    /// Pointer far from the edge never changes the resting state (the overwhelmingly common fold).
    func testMidScreenIsInert() {
        var g = BorderlessDwellGate()
        for y in [50.0, 500, 1400] {
            XCTAssertEqual(g.update(pointerYFromTop: y, now: 100), .hidden)
        }
    }
}
#endif
