#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskVideoHost

/// Replays the `captureUnion` and `captureRetarget` keys of `golden/golden_vectors.json` through the
/// live ``CaptureRegionMath``.
///
/// ## Why this suite exists
///
/// Both keys are frozen in `golden-check.sh` — kept, not regenerated, "XCTest-pinned". **Nothing read
/// either.** `slopdesk-corevectors/main.swift` says their logic "lives solely in the Rust core
/// (`slopdesk_core::capture_region`, reached via the C ABI)" and that "`golden_parity` validates the
/// core against the frozen corpus". There is no `slopdesk_core` crate and no `golden_parity` test;
/// the math is the Swift file this suite imports. Twenty-three cases were pinned by a sentence.
///
/// What they pin that a value comparison would not: the union is compared by BIT PATTERN, so the
/// `!(targetArea > 0.0)` NaN-faithful guard, the ≥-fraction overlap test against the SMALLER area,
/// and the separate multiply that must never become an FMA all stay exactly as they are. The
/// retarget gate's strict `>` — exactly `minDelta` does NOT retarget — is pinned case by case.
///
/// The corpus is READ here, never written.
final class CaptureRegionGoldenVectorTests: XCTestCase {
    private struct WindowCase: Decodable {
        let windowID: UInt32
        let ownerPID: Int32
        let layer: Int
        let fX: UInt64
        let fY: UInt64
        let fW: UInt64
        let fH: UInt64
    }

    private struct UnionCase: Decodable {
        let name: String
        let tX: UInt64
        let tY: UInt64
        let tW: UInt64
        let tH: UInt64
        let targetWindowID: UInt32
        let targetPID: Int32
        let windows: [WindowCase]
        let dX: UInt64
        let dY: UInt64
        let dW: UInt64
        let dH: UInt64
        let minOverlapBits: UInt64
        let outOriginXBits: UInt64
        let outOriginYBits: UInt64
        let outWidthBits: UInt64
        let outHeightBits: UInt64
    }

    private struct RetargetCase: Decodable {
        let name: String
        let cX: UInt64
        let cY: UInt64
        let cW: UInt64
        let cH: UInt64
        let eX: UInt64
        let eY: UInt64
        let eW: UInt64
        let eH: UInt64
        let minDeltaBits: UInt64
        let shouldRetarget: Bool
    }

    func testUnionVectorsStillHold() throws {
        let cases: [UnionCase] = try GoldenCorpus.load("captureUnion")
        XCTAssertEqual(cases.count, 14, "the corpus lost cases — vectors are added, never dropped")

        for testCase in cases {
            let union = CaptureRegionMath.unionRegion(
                targetFrame: Self.rect(testCase.tX, testCase.tY, testCase.tW, testCase.tH),
                targetWindowID: testCase.targetWindowID,
                targetPID: testCase.targetPID,
                windowsInFront: testCase.windows.map {
                    CaptureRegionMath.WindowSnapshot(
                        windowID: $0.windowID,
                        ownerPID: $0.ownerPID,
                        layer: $0.layer,
                        frame: Self.rect($0.fX, $0.fY, $0.fW, $0.fH),
                    )
                },
                displayBounds: Self.rect(testCase.dX, testCase.dY, testCase.dW, testCase.dH),
                minOverlapFraction: Double(bitPattern: testCase.minOverlapBits),
            )
            XCTAssertEqual(Double(union.origin.x).bitPattern, testCase.outOriginXBits, "\(testCase.name): x")
            XCTAssertEqual(Double(union.origin.y).bitPattern, testCase.outOriginYBits, "\(testCase.name): y")
            XCTAssertEqual(Double(union.size.width).bitPattern, testCase.outWidthBits, "\(testCase.name): width")
            XCTAssertEqual(Double(union.size.height).bitPattern, testCase.outHeightBits, "\(testCase.name): height")
        }
    }

    func testRetargetVectorsStillHold() throws {
        let cases: [RetargetCase] = try GoldenCorpus.load("captureRetarget")
        XCTAssertEqual(cases.count, 9, "the corpus lost cases — vectors are added, never dropped")

        for testCase in cases {
            XCTAssertEqual(
                CaptureRegionMath.shouldRetarget(
                    current: Self.rect(testCase.cX, testCase.cY, testCase.cW, testCase.cH),
                    desired: Self.rect(testCase.eX, testCase.eY, testCase.eW, testCase.eH),
                    minDelta: Double(bitPattern: testCase.minDeltaBits),
                ),
                testCase.shouldRetarget,
                testCase.name,
            )
        }
    }

    private static func rect(_ x: UInt64, _ y: UInt64, _ width: UInt64, _ height: UInt64) -> CGRect {
        CGRect(
            x: Double(bitPattern: x),
            y: Double(bitPattern: y),
            width: Double(bitPattern: width),
            height: Double(bitPattern: height),
        )
    }
}
#endif
