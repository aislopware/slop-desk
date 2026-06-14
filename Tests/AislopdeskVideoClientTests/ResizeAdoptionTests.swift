import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// PURE frame-gated resize-adoption decision (``ResizeAdoption/shouldAdopt``): after the host
/// acks an in-session resize, the client adopts the new aspect-fit denominator ONLY when a
/// genuinely-new-size decoded frame arrives — an in-flight OLD-size frame queued behind the ack
/// must be rejected. Both gates (aspect-match AND a real pixel-size change vs the prior frame)
/// are exercised, including the proportional-resize case the aspect gate alone gets wrong.
final class ResizeAdoptionTests: XCTestCase {
    // The decoded buffer is PIXELS (points × captureScale); the acked `pending` is POINTS.
    // Examples below assume a 2× capture scale.

    func testAspectChangingResizeRejectsInFlightOldFrame() {
        // Resize 800×600 (4:3) → 400×600 (2:3). An old-size frame (1600×1200 px, 4:3) arrives
        // after the ack: its aspect does NOT match the new 2:3 target → reject.
        let pending = VideoSize(width: 400, height: 600) // new POINTS, 2:3
        let oldFrame = VideoSize(width: 1600, height: 1200) // old PIXELS, 4:3
        XCTAssertFalse(ResizeAdoption.shouldAdopt(pending: pending, decoded: oldFrame, previousDecoded: oldFrame))
    }

    func testAspectChangingResizeAdoptsNewFrame() {
        // The genuinely-new frame (800×1200 px, 2:3) matches the new aspect AND differs from the
        // prior old-size frame → adopt.
        let pending = VideoSize(width: 400, height: 600) // new POINTS, 2:3
        let newFrame = VideoSize(width: 800, height: 1200) // new PIXELS, 2:3
        let prev = VideoSize(width: 1600, height: 1200) // old PIXELS, 4:3
        XCTAssertTrue(ResizeAdoption.shouldAdopt(pending: pending, decoded: newFrame, previousDecoded: prev))
    }

    func testProportionalResizeRejectsOldFrameByMagnitude() {
        // THE BUG THE MAGNITUDE GATE FIXES: a proportional resize 800×600 → 400×300 (both 4:3).
        // An in-flight old frame (1600×1200 px, 4:3) MATCHES the new aspect, so the aspect gate
        // alone would adopt early. The magnitude gate rejects it (dims unchanged vs the prior).
        let pending = VideoSize(width: 400, height: 300) // new POINTS, 4:3
        let oldFrame = VideoSize(width: 1600, height: 1200) // old PIXELS, 4:3 (same as prior)
        XCTAssertFalse(ResizeAdoption.shouldAdopt(pending: pending, decoded: oldFrame, previousDecoded: oldFrame))
    }

    func testProportionalResizeAdoptsNewFrame() {
        // The genuinely-new proportional frame (800×600 px, 4:3) differs from the prior old frame
        // (1600×1200) → adopt despite identical aspect.
        let pending = VideoSize(width: 400, height: 300) // new POINTS, 4:3
        let newFrame = VideoSize(width: 800, height: 600) // new PIXELS, 4:3
        let prev = VideoSize(width: 1600, height: 1200) // old PIXELS, 4:3
        XCTAssertTrue(ResizeAdoption.shouldAdopt(pending: pending, decoded: newFrame, previousDecoded: prev))
    }

    func testNilPreviousAdoptsWhenAspectMatches() {
        // First frame (no prior baseline) with a matching aspect adopts (magnitude gate defaults
        // to "changed" when there is no previous frame).
        let pending = VideoSize(width: 400, height: 300)
        let frame = VideoSize(width: 800, height: 600)
        XCTAssertTrue(ResizeAdoption.shouldAdopt(pending: pending, decoded: frame, previousDecoded: nil))
    }

    func testDegenerateZeroDimsRejected() {
        let pending = VideoSize(width: 400, height: 300)
        XCTAssertFalse(ResizeAdoption.shouldAdopt(
            pending: pending,
            decoded: VideoSize(width: 0, height: 600),
            previousDecoded: nil,
        ))
        XCTAssertFalse(ResizeAdoption.shouldAdopt(
            pending: VideoSize(width: 0, height: 300),
            decoded: pending,
            previousDecoded: nil,
        ))
    }

    func testWrongAspectNewSizeStillRejected() {
        // A new-size frame whose aspect does NOT match the target is rejected even though its dims
        // changed (guards against adopting a mid-transition frame of the wrong shape).
        let pending = VideoSize(width: 400, height: 300) // 4:3
        let frame = VideoSize(width: 800, height: 1200) // 2:3, changed dims but wrong aspect
        let prev = VideoSize(width: 1600, height: 1200)
        XCTAssertFalse(ResizeAdoption.shouldAdopt(pending: pending, decoded: frame, previousDecoded: prev))
    }
}
