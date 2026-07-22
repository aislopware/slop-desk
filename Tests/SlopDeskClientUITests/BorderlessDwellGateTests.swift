#if os(macOS)
import XCTest
@testable import SlopDeskClientUI

/// The PURE dwell policy behind borderless-fullscreen's local-menu-bar reveal (the Parallels
/// model): a passing top-edge touch stays remote; only a held pointer (≥ dwell) reveals the local
/// menu bar, and moving back into the stream re-arms the gate. Headless — the AppKit layer only
/// maps ``BorderlessDwellGate/Phase`` onto `NSApp.presentationOptions`.
final class BorderlessDwellGateTests: XCTestCase {
    private func gate() -> BorderlessDwellGate {
        BorderlessDwellGate(dwellSeconds: 0.5, revealZonePoints: 2, concealZonePoints: 36)
    }

    /// A bare touch at the top edge must NOT reveal — it arms, and the reveal waits out the dwell.
    /// This is the whole point: that first touch belongs to the REMOTE menu bar.
    func testTopEdgeTouchArmsButDoesNotReveal() {
        var g = gate()
        XCTAssertEqual(g.update(pointerYFromTop: 0, now: 100), .arming(since: 100))
        XCTAssertFalse(g.isRevealed)
        XCTAssertEqual(g.armingDeadline, 100.5, "the AppKit layer schedules its dwell timer here")
    }

    /// Holding the pointer at the edge through the dwell reveals (fed by the timer re-tick — a
    /// motionless pointer emits no move events).
    func testHeldPointerRevealsAfterDwell() {
        var g = gate()
        g.update(pointerYFromTop: 0, now: 100)
        XCTAssertEqual(g.update(pointerYFromTop: 1, now: 100.4), .arming(since: 100), "still inside the dwell")
        XCTAssertEqual(g.update(pointerYFromTop: 1, now: 100.5), .revealed)
        XCTAssertTrue(g.isRevealed)
        XCTAssertNil(g.armingDeadline, "no timer once revealed")
    }

    /// A PASSING touch — enter the zone, leave before the dwell — never reveals: the gate re-arms
    /// silently and remote top-edge clicks are undisturbed.
    func testPassingTouchNeverReveals() {
        var g = gate()
        g.update(pointerYFromTop: 0, now: 100)
        XCTAssertEqual(g.update(pointerYFromTop: 10, now: 100.2), .hidden, "left the edge inside the dwell")
        // Even the timer firing late (stale deadline) cannot reveal — the phase is already hidden.
        XCTAssertEqual(g.update(pointerYFromTop: 10, now: 100.6), .hidden)
    }

    /// Hysteresis: while revealed, working the menu bar (a few points down) keeps it revealed;
    /// only crossing the conceal threshold re-hides — no flicker at the boundary.
    func testConcealHysteresis() {
        var g = gate()
        g.update(pointerYFromTop: 0, now: 100)
        g.update(pointerYFromTop: 0, now: 100.6)
        XCTAssertTrue(g.isRevealed)
        XCTAssertEqual(g.update(pointerYFromTop: 20, now: 101), .revealed, "menu-bar depth stays revealed")
        XCTAssertEqual(g.update(pointerYFromTop: 36, now: 101.2), .hidden, "past the threshold re-hides")
    }

    /// After a conceal the NEXT reveal dwells again — re-touching the edge goes back through arming.
    func testReArmAfterConcealDwellsAgain() {
        var g = gate()
        g.update(pointerYFromTop: 0, now: 100)
        g.update(pointerYFromTop: 0, now: 100.6)
        g.update(pointerYFromTop: 200, now: 101)
        XCTAssertEqual(g.update(pointerYFromTop: 0, now: 102), .arming(since: 102), "no sticky reveal")
    }

    /// Pointer far from the edge never changes the resting state (the overwhelmingly common fold).
    func testMidScreenIsInert() {
        var g = gate()
        for y in [50.0, 500, 1400] {
            XCTAssertEqual(g.update(pointerYFromTop: y, now: 100), .hidden)
        }
    }
}
#endif
