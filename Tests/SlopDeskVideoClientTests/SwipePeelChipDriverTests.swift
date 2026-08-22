import XCTest
@testable import SlopDeskVideoClient
@testable import SlopDeskVideoProtocol

/// Pins ``SwipePeelChipDriver`` — the half of swipe-peel feedback that was written for the Mac and
/// then needed by the phone, and is therefore the half that could have become two laws.
///
/// The planner's own verdicts are pinned in `SwipePeelPlannerTests`; what is asserted here is only
/// what happens BETWEEN a verdict and a surface: when the haptic's rising edge fires, how long a
/// fired chip is held, and which retracts are swallowed. Each of the three is a decision a renderer
/// would otherwise have made for itself.
final class SwipePeelChipDriverTests: XCTestCase {
    private func chip(
        _ direction: SwipeNavRecognizer.Direction = .back, progress: Double = 0.5,
        committed: Bool = false, confirming: Bool = false,
    ) -> SwipePeelChipState {
        SwipePeelChipState(
            direction: direction, progress: progress, committed: committed, confirming: confirming,
        )
    }

    // MARK: The haptic is a rising edge

    func testTheHapticFiresOnceWhenTheChipTurnsSolid() {
        var driver = SwipePeelChipDriver()
        let soft = chip(progress: 0.4)
        XCTAssertEqual(driver.step(.show(soft), showing: nil), .show(soft, haptic: false))

        let solid = chip(progress: 0.9, committed: true)
        XCTAssertEqual(driver.step(.show(solid), showing: soft), .show(solid, haptic: true))
    }

    func testTheHapticDoesNotRefireWhileTheChipStaysSolid() {
        var driver = SwipePeelChipDriver()
        let solid = chip(progress: 0.9, committed: true)
        _ = driver.step(.show(solid), showing: nil)

        // Same commit, more travel: a fill step, not a new "release now navigates".
        let fuller = chip(progress: 1, committed: true)
        XCTAssertEqual(driver.step(.show(fuller), showing: solid), .show(fuller, haptic: false))
    }

    func testFallingBackBelowTheLineRearmsTheHaptic() {
        var driver = SwipePeelChipDriver()
        let solid = chip(progress: 0.9, committed: true)
        _ = driver.step(.show(solid), showing: nil)
        let soft = chip(progress: 0.4)
        _ = driver.step(.show(soft), showing: solid)

        XCTAssertEqual(driver.step(.show(solid), showing: soft), .show(solid, haptic: true))
    }

    // MARK: A publish that changes nothing is not made

    func testAnIdenticalShowIsNotRepublished() {
        var driver = SwipePeelChipDriver()
        let soft = chip(progress: 0.4)
        _ = driver.step(.show(soft), showing: nil)

        XCTAssertEqual(driver.step(.show(soft), showing: soft), SwipePeelChipDriver.Step.none)
    }

    func testAnIdleVerdictIsNothingAtAll() {
        var driver = SwipePeelChipDriver()
        XCTAssertEqual(driver.step(.idle, showing: chip()), SwipePeelChipDriver.Step.none)
    }

    func testARetractOverNothingIsNotAClear() {
        // The history gate relabels every qualifying event of a dead-direction gesture as `.retract`.
        // Answering "clear" each time would re-fire the observable's invalidation for no visible change.
        var driver = SwipePeelChipDriver()
        XCTAssertEqual(driver.step(.retract, showing: nil), SwipePeelChipDriver.Step.none)
    }

    // MARK: The fire, and what outranks a retract

    func testACommitPublishesAConfirmingChipHeldForTheSharedLength() {
        var driver = SwipePeelChipDriver()
        _ = driver.step(.show(chip(progress: 0.9, committed: true)), showing: nil)

        guard case let .confirm(fired, hold) = driver.step(.commit(.forward), showing: nil) else {
            XCTFail("a commit must publish a confirming chip")
            return
        }
        XCTAssertEqual(fired.direction, .forward)
        XCTAssertEqual(fired.progress, 1)
        XCTAssertTrue(fired.committed)
        XCTAssertTrue(fired.confirming)
        XCTAssertEqual(hold, SwipePeelChipDriver.confirmHold)
        XCTAssertGreaterThan(hold, 0, "the hold comes from the door, never from a literal here")
    }

    func testAConfirmingChipSurvivesARetract() {
        // Double-back at the end of history: the NEXT gesture's retract must not erase the previous
        // fire's acknowledgement. Only the pending hold ends it.
        var driver = SwipePeelChipDriver()
        let held = chip(progress: 1, committed: true, confirming: true)
        XCTAssertEqual(driver.step(.retract, showing: held), SwipePeelChipDriver.Step.none)
    }

    func testASameGestureRetractClearsExactlyOnce() {
        var driver = SwipePeelChipDriver()
        let soft = chip(progress: 0.4)
        _ = driver.step(.show(soft), showing: nil)

        XCTAssertEqual(driver.step(.retract, showing: soft), .clear)
        XCTAssertEqual(driver.step(.retract, showing: nil), SwipePeelChipDriver.Step.none)
    }

    func testACommitClearsTheHapticEdgeSoTheNextGestureCanTapAgain() {
        var driver = SwipePeelChipDriver()
        _ = driver.step(.show(chip(progress: 0.9, committed: true)), showing: nil)
        _ = driver.step(.commit(.back), showing: nil)

        let solid = chip(progress: 0.9, committed: true)
        XCTAssertEqual(driver.step(.show(solid), showing: nil), .show(solid, haptic: true))
    }
}
