import XCTest
@testable import AislopdeskClientUI

/// Pins the cinematic-navigation park direction (big-swing C): a hidden tab parks toward its own rail
/// position relative to the shown tab, so the reveal slides in from the direction the user travelled.
@MainActor
final class SplitContainerMotionTests: XCTestCase {
    func testTabAboveShownParksUp() {
        XCTAssertEqual(SplitContainer.parkOffset(index: 0, shownIndex: 2), -14)
    }

    func testTabBelowShownParksDown() {
        XCTAssertEqual(SplitContainer.parkOffset(index: 3, shownIndex: 1), 14)
    }

    func testShownTabAndUnknownIndicesParkInPlace() {
        XCTAssertEqual(SplitContainer.parkOffset(index: 2, shownIndex: 2), 0)
        XCTAssertEqual(SplitContainer.parkOffset(index: nil, shownIndex: 1), 0)
        XCTAssertEqual(SplitContainer.parkOffset(index: 1, shownIndex: nil), 0)
    }

    func testMagnitudeIsTunable() {
        XCTAssertEqual(SplitContainer.parkOffset(index: 0, shownIndex: 1, magnitude: 20), -20)
    }
}
