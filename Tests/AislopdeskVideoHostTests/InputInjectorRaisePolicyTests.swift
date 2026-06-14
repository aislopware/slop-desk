import XCTest
@testable import AislopdeskVideoHost

/// PURE policy for the host's activate-then-control window raise (the CLICK-latency fix). The real
/// ``InputInjector/raiseTargetWindow()`` is AX/TCC-gated and never driven from tests, so the
/// IPC-skip decision is verified here in isolation.
final class InputInjectorRaisePolicyTests: XCTestCase {
    func testSkipsRaiseWhenAlreadyFrontmostAndNotFirst() {
        XCTAssertFalse(
            InputInjectorRaisePolicy.shouldRaise(frontmostPID: 42, targetPID: 42, firstInteraction: false),
            "an already-frontmost target on a repeat interaction skips the expensive AX raise",
        )
    }

    func testRaisesOnFirstInteractionEvenIfAlreadyFrontmost() {
        XCTAssertTrue(
            InputInjectorRaisePolicy.shouldRaise(frontmostPID: 42, targetPID: 42, firstInteraction: true),
            "the first interaction always raises to set kAXMainWindow/kAXFocusedWindow",
        )
    }

    func testRaisesWhenADifferentAppIsFrontmost() {
        XCTAssertTrue(
            InputInjectorRaisePolicy.shouldRaise(frontmostPID: 7, targetPID: 42, firstInteraction: false),
            "a backgrounded target must raise to come frontmost (activate-then-control)",
        )
    }

    func testRaisesWhenFrontmostIsUnknown() {
        XCTAssertTrue(
            InputInjectorRaisePolicy.shouldRaise(frontmostPID: nil, targetPID: 42, firstInteraction: false),
            "an unreadable frontmost errs toward raising so correctness is never weakened",
        )
    }
}
