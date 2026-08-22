import XCTest
@testable import SlopDeskVideoClient
@testable import SlopDeskVideoProtocol

/// Pins ``IndirectPointerPlan`` — the half of "an iPad with a trackpad is a real pointer" that no
/// test can reach through the view it serves (a `CAMetalLayer` over a VideoToolbox decoder).
///
/// The arithmetic itself is pinned in Rust; what is asserted here is the FACE, and specifically the
/// two things a marshalling layer can get wrong on its own: which `MouseButton` a bit indexes, and
/// what an empty set answers. A bit-index drift would turn an iPad's right click into a left one at
/// the host with every Rust test still green.
final class IndirectPointerPlanTests: XCTestCase {
    // `UIEventButtonMask.rawValue`'s own type, so these are the literals the view really passes.
    private let primary: Int = 1 << 0
    private let secondary: Int = 1 << 1
    private let middle: Int = 1 << 2

    // MARK: The bit set is the wire's own button ordinal

    func testEachBitIndexesTheButtonTheWireCallsIt() {
        // The door hands back a bit SET and this side walks it with a shift. If the two vocabularies
        // ever drift, a right click arrives at the host as a left one — silently, and only on iPad.
        for button in MouseButton.allCases {
            XCTAssertEqual(IndirectPointerPlan.buttons(in: 1 << button.rawValue), [button])
        }
    }

    func testAnEmptySetIsAnEmptyList() {
        // The property that lets a caller loop over the answer instead of testing the set first.
        XCTAssertTrue(IndirectPointerPlan.buttons(in: 0).isEmpty)
    }

    func testTheButtonsComeBackInWireOrder() {
        let all = IndirectPointerPlan.buttonTransitions(held: 0, mask: primary | secondary | middle)
        XCTAssertEqual(IndirectPointerPlan.buttons(in: all.pressed), [.left, .right, .other])
    }

    // MARK: The diff — the reason this is not a level forward

    func testTheFirstPressIsAnEdge() {
        let change = IndirectPointerPlan.buttonTransitions(held: 0, mask: primary)
        XCTAssertEqual(IndirectPointerPlan.buttons(in: change.pressed), [.left])
        XCTAssertEqual(change.released, 0)
    }

    func testTheSameMaskTwiceChangesNothing() {
        // What makes one call site safe for press, drag AND release: UIKit reports the LEVEL on every
        // event of the gesture, so a drag would otherwise re-send the press it already made.
        let first = IndirectPointerPlan.buttonTransitions(held: 0, mask: primary)
        let again = IndirectPointerPlan.buttonTransitions(held: first.held, mask: primary)
        XCTAssertEqual(again.pressed, 0)
        XCTAssertEqual(again.released, 0)
        XCTAssertEqual(again.held, first.held)
    }

    func testAnEmptyMaskReleasesEverythingStillHeld() {
        // The lift. A button left down outlives the pane on a host whose event source is
        // process-global, so this is the transition that must never be missed.
        let held = IndirectPointerPlan.buttonTransitions(held: 0, mask: primary | middle).held
        let lift = IndirectPointerPlan.buttonTransitions(held: held, mask: 0)
        XCTAssertEqual(IndirectPointerPlan.buttons(in: lift.released), [.left, .other])
        XCTAssertEqual(lift.pressed, 0)
        XCTAssertEqual(lift.held, 0)
    }

    func testAnUnnamedButtonIsStillAPress() {
        // UIKit names two buttons and leaves the rest of the mask unnamed rather than absent. Dropping
        // them would make a paste-on-middle-click silently do nothing.
        let change = IndirectPointerPlan.buttonTransitions(held: 0, mask: 1 << 9)
        XCTAssertEqual(IndirectPointerPlan.buttons(in: change.pressed), [.other])
    }

    // MARK: The scroll phase — a fourth encoding of the same three edges

    func testATrackpadScrollSpellsTheSameGestureAFingerDoes() {
        XCTAssertEqual(
            IndirectPointerPlan.scrollPhase(gestureState: 1), // .began
            TouchPointerPlan.scrollPhase(isFirst: true, isLast: false),
        )
        XCTAssertEqual(
            IndirectPointerPlan.scrollPhase(gestureState: 2), // .changed
            TouchPointerPlan.scrollPhase(isFirst: false, isLast: false),
        )
        XCTAssertEqual(
            IndirectPointerPlan.scrollPhase(gestureState: 3), // .ended
            TouchPointerPlan.scrollPhase(isFirst: false, isLast: true),
        )
    }

    func testAnAbandonedScrollEndsRatherThanCancelling() {
        // The host has one replay for a finished gesture and none for an abandoned one; a phase it
        // cannot replay would leave the remote gesture open until the next scroll closed it.
        let ended = TouchPointerPlan.scrollPhase(isFirst: false, isLast: true)
        XCTAssertEqual(IndirectPointerPlan.scrollPhase(gestureState: 4), ended) // .cancelled
        XCTAssertEqual(IndirectPointerPlan.scrollPhase(gestureState: 5), ended) // .failed
    }

    func testNothingRecognisedYetIsAWheelTickRatherThanAGuess() {
        XCTAssertEqual(IndirectPointerPlan.scrollPhase(gestureState: 0), 0) // .possible
    }
}
