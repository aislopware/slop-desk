#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskVideoHost

/// Replays the `windowPlacement` and `windowFits` keys of `golden/golden_vectors.json` through the
/// live ``WindowPlacementMath``.
///
/// ## Why this suite exists
///
/// `golden-check.sh` lists both keys among the frozen ones — in the corpus, not regenerated —
/// "XCTest-pinned, not emitted". **No test read either of them.** `slopdesk-corevectors/main.swift`
/// carries a note saying the logic "lives solely in the Rust core (`slopdesk_core::window_placement`,
/// reached via the C ABI)" and that "the `golden_parity` test still validates the core against the
/// frozen corpus". Neither is true any more: there is no `slopdesk_core` crate and no `golden_parity`
/// test anywhere in the repository, and the math is the Swift file this suite imports. Nineteen
/// frozen cases were pinned by a sentence.
///
/// The vectors are bit patterns, so what they pin is exact: the CG-standardised width against the
/// raw window field, the ordered ternary min that a `Swift.min` would get wrong on NaN, and the
/// half-point resize predicate. Those are precisely the properties a port to Rust has to preserve,
/// which is why the pin is worth reviving rather than deleting.
///
/// The corpus is READ here, never written. A vector that disagrees is a regression in the math.
final class WindowPlacementGoldenVectorTests: XCTestCase {
    private struct PlacementCase: Decodable {
        let name: String
        let winWBits: UInt64
        let winHBits: UInt64
        let dX: UInt64
        let dY: UInt64
        let dW: UInt64
        let dH: UInt64
        let outOriginXBits: UInt64
        let outOriginYBits: UInt64
        let outWidthBits: UInt64
        let outHeightBits: UInt64
        let needsResize: Bool
    }

    private struct FitsCase: Decodable {
        let name: String
        let sizeWBits: UInt64
        let sizeHBits: UInt64
        let bX: UInt64
        let bY: UInt64
        let bW: UInt64
        let bH: UInt64
        let fits: Bool
    }

    func testPlacementVectorsStillHold() throws {
        let cases: [PlacementCase] = try GoldenCorpus.load("windowPlacement")
        XCTAssertEqual(cases.count, 11, "the corpus lost cases — vectors are added, never dropped")

        for testCase in cases {
            let placed = WindowPlacementMath.placement(
                windowSize: CGSize(
                    width: Double(bitPattern: testCase.winWBits),
                    height: Double(bitPattern: testCase.winHBits),
                ),
                displayBounds: CGRect(
                    x: Double(bitPattern: testCase.dX),
                    y: Double(bitPattern: testCase.dY),
                    width: Double(bitPattern: testCase.dW),
                    height: Double(bitPattern: testCase.dH),
                ),
            )
            // Bit patterns, not `==`: the vectors exist because a -0.0 or a NaN that compares equal
            // is still a different answer, and a port that produced one would pass a value check.
            XCTAssertEqual(Double(placed.origin.x).bitPattern, testCase.outOriginXBits, "\(testCase.name): origin.x")
            XCTAssertEqual(Double(placed.origin.y).bitPattern, testCase.outOriginYBits, "\(testCase.name): origin.y")
            XCTAssertEqual(Double(placed.size.width).bitPattern, testCase.outWidthBits, "\(testCase.name): width")
            XCTAssertEqual(Double(placed.size.height).bitPattern, testCase.outHeightBits, "\(testCase.name): height")
            XCTAssertEqual(placed.needsResize, testCase.needsResize, "\(testCase.name): needsResize")
        }
    }

    func testFitsVectorsStillHold() throws {
        let cases: [FitsCase] = try GoldenCorpus.load("windowFits")
        XCTAssertEqual(cases.count, 8, "the corpus lost cases — vectors are added, never dropped")

        for testCase in cases {
            let answer = WindowPlacementMath.fits(
                CGSize(
                    width: Double(bitPattern: testCase.sizeWBits),
                    height: Double(bitPattern: testCase.sizeHBits),
                ),
                within: CGRect(
                    x: Double(bitPattern: testCase.bX),
                    y: Double(bitPattern: testCase.bY),
                    width: Double(bitPattern: testCase.bW),
                    height: Double(bitPattern: testCase.bH),
                ),
            )
            XCTAssertEqual(answer, testCase.fits, "\(testCase.name)")
        }
    }
}
#endif
