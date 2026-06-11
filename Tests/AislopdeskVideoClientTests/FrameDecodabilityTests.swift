import XCTest
@testable import AislopdeskVideoClient

/// R15 #9 regression: a ZERO-byte reassembled frame must be triaged BEFORE the decoder, never
/// submitted as a degenerate zero-length sample buffer (which fails the decode and drives a
/// needless invalidateSession + IDR recovery churn). The triage is pure — no VideoToolbox.
final class FrameDecodabilityTests: XCTestCase {

    func testNonEmptyDeltaIsDecodable() {
        XCTAssertEqual(FrameDecodability.classify(keyframe: false, byteCount: 1), .decodable)
        XCTAssertEqual(FrameDecodability.classify(keyframe: false, byteCount: 4096), .decodable)
    }

    func testNonEmptyKeyframeIsDecodable() {
        XCTAssertEqual(FrameDecodability.classify(keyframe: true, byteCount: 1), .decodable,
                       "a real (non-empty) keyframe decodes normally — only the zero-byte case is special")
        XCTAssertEqual(FrameDecodability.classify(keyframe: true, byteCount: 65_536), .decodable)
    }

    func testEmptyDeltaDropsSilently() {
        // An empty delta is dropped without touching the (healthy) session — no IDR storm for a
        // single corrupt/empty fragment; the reassembler's loss recovery covers a genuine gap.
        XCTAssertEqual(FrameDecodability.classify(keyframe: false, byteCount: 0), .dropSilently)
    }

    func testEmptyKeyframeRequestsKeyframeWithoutChurn() {
        // An empty IDR means the keyframe itself was empty → ask for a fresh one. The decoder maps
        // this to `awaitingKeyframe`, whose caller requests an IDR WITHOUT invalidating the session.
        XCTAssertEqual(FrameDecodability.classify(keyframe: true, byteCount: 0), .requestKeyframe)
    }
}
