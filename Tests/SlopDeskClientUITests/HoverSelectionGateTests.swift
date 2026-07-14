// HoverSelectionGateTests — pins the two anti-feedback-loop contracts of ``HoverSelectionGate``
// (the palette-family hover→selection arbiter):
//
// 1. a hover-driven selection change suppresses exactly ONE auto-scroll (check-and-clear), keyboard
//    nav scrolls again immediately after;
// 2. a hover event at an UNCHANGED global pointer location (the list scrolling under a parked mouse)
//    is rejected — only genuine movement may steal the selection.

import XCTest
@testable import SlopDeskClientUI

@MainActor
final class HoverSelectionGateTests: XCTestCase {
    // MARK: - Movement gate

    func testFirstHoverOfAPresentationIsAdmitted() {
        let gate = HoverSelectionGate()
        XCTAssertTrue(
            gate.admitHover(at: CGPoint(x: 100, y: 100)),
            "the first hover event has no prior location to compare — always genuine",
        )
    }

    func testHoverAtUnchangedLocationIsRejected() {
        // A keyboard scrollTo slides a new row under the PARKED pointer — AppKit re-fires hover at the
        // same global location. Admitting it would yank the selection back to the mouse row.
        let gate = HoverSelectionGate()
        XCTAssertTrue(gate.admitHover(at: CGPoint(x: 100, y: 100)))
        XCTAssertFalse(
            gate.admitHover(at: CGPoint(x: 100, y: 100)),
            "the list moving under a stationary pointer is not a hover intent",
        )
    }

    func testHoverAfterGenuineMovementIsAdmitted() {
        let gate = HoverSelectionGate()
        XCTAssertTrue(gate.admitHover(at: CGPoint(x: 100, y: 100)))
        XCTAssertFalse(gate.admitHover(at: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(
            gate.admitHover(at: CGPoint(x: 100, y: 101)),
            "any real pointer movement re-opens the gate",
        )
    }

    func testRejectedHoverStillUpdatesTheComparisonBaseline() {
        // Two scroll-induced re-fires in a row must BOTH be rejected — the baseline is "last event",
        // not "last admitted event", so a rejected event can't make its twin look like movement.
        let gate = HoverSelectionGate()
        XCTAssertTrue(gate.admitHover(at: CGPoint(x: 50, y: 50)))
        XCTAssertFalse(gate.admitHover(at: CGPoint(x: 50, y: 50)))
        XCTAssertFalse(gate.admitHover(at: CGPoint(x: 50, y: 50)))
    }

    // MARK: - Auto-scroll suppression

    func testKeyboardSelectionChangeAutoScrolls() {
        let gate = HoverSelectionGate()
        XCTAssertTrue(
            gate.shouldAutoScrollOnSelectionChange(),
            "an un-marked (keyboard / programmatic) selection change keeps the follow-scroll",
        )
    }

    func testHoverDrivenSelectionChangeSuppressesExactlyOneScroll() {
        let gate = HoverSelectionGate()
        gate.noteHoverDrivenSelection()
        XCTAssertFalse(
            gate.shouldAutoScrollOnSelectionChange(),
            "the hover-driven change itself must not scroll (loop #1: the list follows the mouse)",
        )
        XCTAssertTrue(
            gate.shouldAutoScrollOnSelectionChange(),
            "the mark is check-and-clear — the NEXT (keyboard) change scrolls again",
        )
    }
}
