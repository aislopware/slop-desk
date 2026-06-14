import XCTest
@testable import AislopdeskVideoClient

/// WF-5 (#7) PURE input-motion-interval resolution. The motion pump flushes the most-recent deferred
/// pointer move once per this interval (most-recent-wins; absolute coords; NO delta-summing). The
/// pump/pipeline are @MainActor + view-owned and never instantiated here; this pins the env→interval
/// math: the new responsive default and the HZ/MS precedence + clamp.
final class MotionIntervalTests: XCTestCase {
    private let defaultInterval = 1.0 / 120.0

    // The new DEFAULT is the more-responsive 120Hz (~8.3ms), down from the old 1/60 (~16.7ms).
    func testDefaultIsResponsive120Hz() {
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: nil, ms: nil), defaultInterval, accuracy: 1e-12)
    }

    // AISLOPDESK_INPUT_HZ → 1/hz.
    func testHzMapsToInterval() {
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: "60", ms: nil), 1.0 / 60.0, accuracy: 1e-12)
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: "240", ms: nil), 1.0 / 240.0, accuracy: 1e-12)
    }

    // AISLOPDESK_INPUT_INTERVAL_MS → ms/1000.
    func testMsMapsToInterval() {
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: nil, ms: "10"), 0.010, accuracy: 1e-12)
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: nil, ms: "5"), 0.005, accuracy: 1e-12)
    }

    // HZ takes precedence over MS when BOTH are set.
    func testHzWinsOverMs() {
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: "200", ms: "50"), 1.0 / 200.0, accuracy: 1e-12)
    }

    // Out-of-range / unparseable HZ falls through to MS, then to the default.
    func testBadHzFallsThrough() {
        // hz=0 (below 1) is invalid → use ms
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: "0", ms: "20"), 0.020, accuracy: 1e-12)
        // hz=5000 (above 1000) is invalid → use ms
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: "5000", ms: "20"), 0.020, accuracy: 1e-12)
        // both invalid → default
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: "nope", ms: "0"), defaultInterval, accuracy: 1e-12)
    }

    // Out-of-range / unparseable MS → default.
    func testBadMsFallsToDefault() {
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: nil, ms: "0"), defaultInterval, accuracy: 1e-12)
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: nil, ms: "9999"), defaultInterval, accuracy: 1e-12)
        XCTAssertEqual(
            VideoWindowPipeline.resolveMotionInterval(hz: nil, ms: "garbage"),
            defaultInterval,
            accuracy: 1e-12,
        )
    }

    // Clamp boundaries are inclusive.
    func testClampBoundaries() {
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: "1000", ms: nil), 1.0 / 1000.0, accuracy: 1e-12)
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: "1", ms: nil), 1.0, accuracy: 1e-12)
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: nil, ms: "1000"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(VideoWindowPipeline.resolveMotionInterval(hz: nil, ms: "1"), 0.001, accuracy: 1e-12)
    }
}
