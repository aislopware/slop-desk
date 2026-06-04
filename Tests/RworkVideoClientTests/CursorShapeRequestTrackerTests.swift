import XCTest
@testable import RworkVideoClient
import RworkVideoProtocol

/// FIX B (cursor-shape self-heal): pure decision for re-requesting a missing cursor shape.
///
/// A cursor shape bitmap ships ONCE per shapeID over the cursor socket; a lost (or over-MTU,
/// IP-fragment-lost) shape would leave the overlay permanently wrong/invisible (the host strips
/// the real cursor). When a POSITION update references an UNKNOWN shapeID the client re-requests
/// it on the recovery channel — but at most once per `reRequestInterval` so the ~120 Hz position
/// stream never floods the channel. No socket, no clock (the caller passes `now`).
final class CursorShapeRequestTrackerTests: XCTestCase {

    func testUnknownShapeTriggersExactlyOneRequestThenDebounces() {
        var t = CursorShapeRequestTracker(reRequestInterval: 0.5)
        // First sighting of an unknown id at t=0 → request.
        XCTAssertTrue(t.shouldRequest(shapeID: 5, now: 0))
        // Subsequent ~120 Hz position updates within the interval → no flood.
        XCTAssertFalse(t.shouldRequest(shapeID: 5, now: 0.01))
        XCTAssertFalse(t.shouldRequest(shapeID: 5, now: 0.4))
        // Past the interval, still missing → re-request (the prior re-ship may have been lost too).
        XCTAssertTrue(t.shouldRequest(shapeID: 5, now: 0.51))
    }

    func testKnownShapeNeverRequested() {
        var t = CursorShapeRequestTracker(reRequestInterval: 0.5)
        t.noteShapeArrived(9)
        XCTAssertTrue(t.isKnown(9))
        XCTAssertFalse(t.shouldRequest(shapeID: 9, now: 0), "a cached shape is never re-requested")
        XCTAssertFalse(t.shouldRequest(shapeID: 9, now: 100))
    }

    func testArrivalStopsFurtherRequests() {
        var t = CursorShapeRequestTracker(reRequestInterval: 0.5)
        XCTAssertTrue(t.shouldRequest(shapeID: 3, now: 0))      // missing → request
        t.noteShapeArrived(3)                                  // re-ship lands
        XCTAssertTrue(t.isKnown(3))
        // Even well past the debounce window, a now-cached shape must not re-request.
        XCTAssertFalse(t.shouldRequest(shapeID: 3, now: 5))
    }

    func testDistinctMissingShapesTrackedIndependently() {
        var t = CursorShapeRequestTracker(reRequestInterval: 0.5)
        XCTAssertTrue(t.shouldRequest(shapeID: 1, now: 0))
        XCTAssertTrue(t.shouldRequest(shapeID: 2, now: 0), "a different missing id requests independently")
        // id 1 is still within its own debounce window.
        XCTAssertFalse(t.shouldRequest(shapeID: 1, now: 0.1))
        // id 2 likewise.
        XCTAssertFalse(t.shouldRequest(shapeID: 2, now: 0.1))
    }

    func testReRequestClearedAfterArrivalReArmsImmediately() {
        // If a shape arrives then is somehow dropped from the client cache later in another
        // session, this tracker is per-session: arrival clears the per-id request clock, so a
        // genuinely-fresh unknown id requests at once rather than waiting out a stale debounce.
        var t = CursorShapeRequestTracker(reRequestInterval: 0.5)
        XCTAssertTrue(t.shouldRequest(shapeID: 4, now: 0))
        t.noteShapeArrived(4)
        // (A new id, distinct from any prior, requests immediately.)
        XCTAssertTrue(t.shouldRequest(shapeID: 8, now: 0.1))
    }
}
