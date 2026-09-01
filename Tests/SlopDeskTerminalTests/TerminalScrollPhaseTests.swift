#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import XCTest
@testable import SlopDeskTerminal

/// Pins the fold from AppKit's TWO phase words onto the one question the far side asks.
///
/// The reason this needs a test at all: `NSEvent` reports a gesture phase and a momentum phase
/// separately, and the sequence that matters — fingers down, fingers up INTO a fling, fling coasts,
/// fling stops — sets `.ended` on the gesture word in the middle of it. Reading that word alone
/// would call the scroll over while a dozen momentum deltas were still coming, and the row snap
/// taken there would be undone by every one of them.
final class TerminalScrollPhaseTests: XCTestCase {
    /// A notched wheel names neither word, and there is no gesture to wait for.
    func testAWheelNotchIsDiscrete() {
        XCTAssertEqual(TerminalScrollPhase(gesture: [], momentum: []), .discrete)
    }

    /// The whole trackpad sequence, in order, as one flick with a fling on the end.
    func testAFlickWithMomentumSettlesOnceAndOnlyAtTheVeryEnd() {
        let sequence: [(NSEvent.Phase, NSEvent.Phase, TerminalScrollPhase)] = [
            (.began, [], .live),
            (.changed, [], .live),
            // The lift. `.ended` on the GESTURE word, with the fling still to come — reading this
            // word alone is the bug.
            (.ended, .began, .live),
            ([], .changed, .live),
            ([], .ended, .ended),
        ]
        for (gesture, momentum, want) in sequence {
            XCTAssertEqual(
                TerminalScrollPhase(gesture: gesture, momentum: momentum), want,
                "gesture \(gesture.rawValue), momentum \(momentum.rawValue)",
            )
        }
    }

    /// A drag that stops dead names no momentum at all, so the lift IS the end.
    func testAGestureThatEndsWithoutAFlingSettlesAtTheLift() {
        XCTAssertEqual(TerminalScrollPhase(gesture: .ended, momentum: []), .ended)
        XCTAssertEqual(TerminalScrollPhase(gesture: .cancelled, momentum: []), .ended)
    }

    /// A cancelled fling is a finished one: something interrupted it, and the offset it left behind
    /// still owes a snap.
    func testACancelledFlingStillSettles() {
        XCTAssertEqual(TerminalScrollPhase(gesture: [], momentum: .cancelled), .ended)
    }

    /// The codes are the far side's `ALL` order, which `slopdesk_term_surface_scroll_points` indexes
    /// into — a reorder here would silently mean a different phase.
    func testTheCodesArePinned() {
        XCTAssertEqual(TerminalScrollPhase.discrete.code, 0)
        XCTAssertEqual(TerminalScrollPhase.live.code, 1)
        XCTAssertEqual(TerminalScrollPhase.ended.code, 2)
    }
}
#endif
