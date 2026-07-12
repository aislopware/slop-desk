#if os(macOS)
import XCTest
@testable import SlopDeskVideoHost

/// MOTION-KEYED CONSTANT QP (Parsec-style scroll): pure policy for the const-QP live delta
/// path. The HW encoder it feeds is never instantiated here (hang-safety); this pins the rule that keeps
/// STATIC frames byte-identical to pure const-QP while FORCING a MOTION frame to a coarser constant QP
/// (Min==Max==q) so VT shrinks the fat scroll frame.
final class ConstQPBandTests: XCTestCase {
    /// No measurement (adaptive-QP off / first frame) ⇒ pure const-QP: the applied QP is the floor.
    func testNilCeilingIsPureConstQP() {
        XCTAssertEqual(VideoEncoder.constQPForFrame(floor: 24, perFrameMaxQP: nil), 24)
    }

    /// A STATIC measurement (the law returns the sharp end == floor) ⇒ floor (constant, sharp).
    func testCeilingAtFloorIsConstant() {
        XCTAssertEqual(VideoEncoder.constQPForFrame(floor: 24, perFrameMaxQP: 24), 24)
    }

    /// MOTION: the content-driven QP rises above the floor ⇒ that coarser QP is applied as the constant
    /// (Min==Max) so VT is forced to shrink the fat scroll frame.
    func testMotionRaisesQPAboveFloor() {
        XCTAssertEqual(VideoEncoder.constQPForFrame(floor: 24, perFrameMaxQP: 40), 40)
    }

    /// A measurement BELOW the floor is clamped UP to the floor — the sharp floor always wins (a coarser
    /// link Q must never let a frame go sharper than the configured constant-QP floor).
    func testCeilingBelowFloorClampsToFloor() {
        XCTAssertEqual(VideoEncoder.constQPForFrame(floor: 30, perFrameMaxQP: 22), 30)
    }

    /// The applied QP is never below the floor and never below the supplied ceiling — the max of both.
    func testAppliedQPIsNeverBelowFloor() {
        for floor in [1, 18, 24, 36, 51] {
            for ceil: Int? in [nil, 1, 20, 24, 36, 51] {
                let q = VideoEncoder.constQPForFrame(floor: floor, perFrameMaxQP: ceil)
                XCTAssertGreaterThanOrEqual(q, floor, "applied QP must never undercut the sharp floor")
                if let c = ceil { XCTAssertEqual(q, max(floor, c)) }
            }
        }
    }
}
#endif
