import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// PURE logic only — exercises the host-side ``SizeNegotiation`` clamp + epoch
/// monotonicity. NO SCStream / AX is touched (hang-safety rule).
final class SizeNegotiationTests: XCTestCase {
    private let minSize = VideoSize(width: 320, height: 240)
    private let maxSize = VideoSize(width: 3840, height: 2160)

    // MARK: clamp

    func testWithinBoundsIsIdentity() {
        let (w, h) = SizeNegotiation.clamp(desired: VideoSize(width: 1280, height: 800), min: minSize, max: maxSize)
        XCTAssertEqual(w, 1280)
        XCTAssertEqual(h, 800)
    }

    func testBelowMinClampsUpToMin() {
        let (w, h) = SizeNegotiation.clamp(desired: VideoSize(width: 100, height: 50), min: minSize, max: maxSize)
        XCTAssertEqual(w, 320)
        XCTAssertEqual(h, 240)
    }

    func testAboveMaxClampsDownToMax() {
        let (w, h) = SizeNegotiation.clamp(desired: VideoSize(width: 9999, height: 9999), min: minSize, max: maxSize)
        XCTAssertEqual(w, 3840)
        XCTAssertEqual(h, 2160)
    }

    func testZeroDesiredNeverReturnsZero() {
        let (w, h) = SizeNegotiation.clamp(desired: VideoSize(width: 0, height: 0), min: minSize, max: maxSize)
        XCTAssertEqual(w, 320, "zero desired clamps up to the min, never 0")
        XCTAssertEqual(h, 240)
    }

    func testZeroMinPolicyStillNeverReturnsZero() {
        // A degenerate (0,0) min floor must still yield a non-zero, UInt16-safe size.
        let (w, h) = SizeNegotiation.clamp(
            desired: VideoSize(width: 0, height: 0),
            min: VideoSize(width: 0, height: 0),
            max: maxSize,
        )
        XCTAssertGreaterThanOrEqual(w, 1)
        XCTAssertGreaterThanOrEqual(h, 1)
    }

    func testRoundsToNearestInt() {
        let (w, h) = SizeNegotiation.clamp(desired: VideoSize(width: 1280.4, height: 800.6), min: minSize, max: maxSize)
        XCTAssertEqual(w, 1280)
        XCTAssertEqual(h, 801)
    }

    func testUInt16SafetyClampsHugeAtMaxPolicyAndCeiling() {
        // Max policy itself is huge → ceilinged at UInt16.max; desired beyond it clamps there.
        let (w, h) = SizeNegotiation.clamp(
            desired: VideoSize(width: 1_000_000, height: 1_000_000),
            min: minSize,
            max: VideoSize(width: 1_000_000, height: 1_000_000),
        )
        XCTAssertEqual(w, UInt16.max)
        XCTAssertEqual(h, UInt16.max)
    }

    func testAspectClampPerAxisIndependently() {
        // A tall-narrow desired: width below min, height above max → each axis clamps to
        // its own bound (no aspect coupling — capture is configured per axis).
        let (w, h) = SizeNegotiation.clamp(desired: VideoSize(width: 100, height: 9999), min: minSize, max: maxSize)
        XCTAssertEqual(w, 320)
        XCTAssertEqual(h, 2160)
    }

    func testNonFiniteDesiredCollapsesToLowerBoundNotTrap() {
        // A hostile/garbage desired (NaN/inf) must not trap UInt16(Double) — it collapses
        // to the lower bound.
        let (w, h) = SizeNegotiation.clamp(
            desired: VideoSize(width: .nan, height: .infinity),
            min: minSize,
            max: maxSize,
        )
        XCTAssertEqual(w, 320, "NaN width collapses to the width min, never traps")
        XCTAssertEqual(h, 240, "inf height collapses to the height min, never overflows/traps")
    }

    func testSwappedPolicyStillClampsIntoValidRange() {
        // A degenerate policy with min > max must still produce a valid clamp (ordered).
        let (w, h) = SizeNegotiation.clamp(
            desired: VideoSize(width: 1280, height: 800),
            min: VideoSize(width: 3840, height: 2160),
            max: VideoSize(width: 320, height: 240),
        )
        XCTAssertGreaterThanOrEqual(w, 1)
        XCTAssertGreaterThanOrEqual(h, 1)
        XCTAssertLessThanOrEqual(w, 3840)
        XCTAssertLessThanOrEqual(h, 2160)
    }

    // MARK: epoch monotonicity

    func testEpochStaleWhenLessThanOrEqualToLastApplied() {
        XCTAssertTrue(SizeNegotiation.isStaleEpoch(5, lastApplied: 5), "equal epoch is a dup → stale")
        XCTAssertTrue(SizeNegotiation.isStaleEpoch(3, lastApplied: 5), "older epoch → stale")
        XCTAssertTrue(SizeNegotiation.isStaleEpoch(0, lastApplied: 5))
    }

    func testEpochFreshWhenGreaterThanLastApplied() {
        XCTAssertFalse(SizeNegotiation.isStaleEpoch(6, lastApplied: 5))
        XCTAssertFalse(SizeNegotiation.isStaleEpoch(.max, lastApplied: 5))
    }

    func testFirstEpochAgainstZeroIsNeverStale() {
        // lastApplied == 0 ⇒ none applied yet; any epoch >= 1 wins.
        XCTAssertFalse(SizeNegotiation.isStaleEpoch(1, lastApplied: 0))
        // epoch 0 against 0 is still "stale" (no real request carries epoch 0 once the
        // client increments before sending).
        XCTAssertTrue(SizeNegotiation.isStaleEpoch(0, lastApplied: 0))
    }
}
