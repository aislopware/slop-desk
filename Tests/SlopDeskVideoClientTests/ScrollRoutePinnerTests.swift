import XCTest
@testable import SlopDeskVideoClient

/// Pins the per-gesture scroll-route pin (doc 05 §8): the remote-vs-canvas choice is decided
/// where the gesture STARTS and held through its momentum tail — a mid-gesture focus flip must
/// not reroute the inertia — while phase-less wheel ticks keep the live per-event decision.
final class ScrollRoutePinnerTests: XCTestCase {
    func testRemotePinnedAtBeganHoldsThroughFocusFlipAndMomentum() {
        var pinner = ScrollRoutePinner()
        XCTAssertTrue(pinner.route(liveRemote: true, scrollPhase: 1, momentumPhase: 0))
        // Focus flips away mid-gesture (liveRemote now false) — the tail must keep forwarding.
        XCTAssertTrue(pinner.route(liveRemote: false, scrollPhase: 2, momentumPhase: 0))
        XCTAssertTrue(pinner.route(liveRemote: false, scrollPhase: 4, momentumPhase: 0))
        XCTAssertTrue(pinner.route(liveRemote: false, scrollPhase: 0, momentumPhase: 1))
        XCTAssertTrue(pinner.route(liveRemote: false, scrollPhase: 0, momentumPhase: 2))
        // Momentum END concludes the gesture — routed by the pin one last time…
        XCTAssertTrue(pinner.route(liveRemote: false, scrollPhase: 0, momentumPhase: 3))
        // …and the NEXT gesture re-decides from the live state.
        XCTAssertFalse(pinner.route(liveRemote: false, scrollPhase: 1, momentumPhase: 0))
    }

    func testCanvasPinnedGestureStaysCanvasWhenPaneActivates() {
        var pinner = ScrollRoutePinner()
        XCTAssertFalse(pinner.route(liveRemote: false, scrollPhase: 1, momentumPhase: 0))
        // The pane becomes active mid-pan (click-through focus) — the pan must not suddenly
        // start scrolling the remote window.
        XCTAssertFalse(pinner.route(liveRemote: true, scrollPhase: 2, momentumPhase: 0))
        XCTAssertFalse(pinner.route(liveRemote: true, scrollPhase: 0, momentumPhase: 2))
    }

    func testWheelTicksAlwaysRouteLive() {
        var pinner = ScrollRoutePinner()
        // Classic-mouse notches carry no phases — every tick follows the live decision, and a
        // stale pin from an unconcluded trackpad gesture must not capture them.
        XCTAssertTrue(pinner.route(liveRemote: true, scrollPhase: 0, momentumPhase: 0))
        XCTAssertFalse(pinner.route(liveRemote: false, scrollPhase: 0, momentumPhase: 0))
        _ = pinner.route(liveRemote: true, scrollPhase: 1, momentumPhase: 0) // pin remote…
        XCTAssertFalse(pinner.route(liveRemote: false, scrollPhase: 0, momentumPhase: 0)) // …tick stays live
    }

    func testCancelledGestureClearsThePin() {
        var pinner = ScrollRoutePinner()
        XCTAssertTrue(pinner.route(liveRemote: true, scrollPhase: 1, momentumPhase: 0))
        XCTAssertTrue(pinner.route(liveRemote: false, scrollPhase: 8, momentumPhase: 0))
        // Post-cancel there is no pin: a mid-gesture-shaped straggler falls back to live.
        XCTAssertFalse(pinner.route(liveRemote: false, scrollPhase: 2, momentumPhase: 0))
    }

    func testMayBeginPinsLikeBegan() {
        var pinner = ScrollRoutePinner()
        XCTAssertTrue(pinner.route(liveRemote: true, scrollPhase: 128, momentumPhase: 0))
        XCTAssertTrue(pinner.route(liveRemote: false, scrollPhase: 2, momentumPhase: 0))
    }

    func testMidGestureEventWithoutPinFallsBackToLive() {
        // The view mounted mid-gesture (its began went to a previous view) — no pin exists, so
        // the live decision routes rather than dropping the event.
        var pinner = ScrollRoutePinner()
        XCTAssertTrue(pinner.route(liveRemote: true, scrollPhase: 2, momentumPhase: 0))
    }
}
