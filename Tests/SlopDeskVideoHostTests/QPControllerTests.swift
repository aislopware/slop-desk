import XCTest
@testable import SlopDeskVideoHost

/// Mirror of the core `qp_controller::tests` — proves the Swift `QPController` AIMD-on-QP agrees with
/// the Rust law (integer → exact, no float-golden needed). Congestion coarsens fast; clean sharpens
/// slowly; the senses are flipped (QP is inverse quality).
final class QPControllerTests: XCTestCase {
    private func ctrl(seed: Int = 26) -> QPController {
        QPController(qSharp: 26, qCoarse: 40, upStep: 3, downInterval: 4, seedQ: seed)
    }

    func testSeedClampedIntoRange() {
        XCTAssertEqual(ctrl(seed: 10).q, 26)
        XCTAssertEqual(ctrl(seed: 99).q, 40)
        XCTAssertEqual(ctrl(seed: 30).q, 30)
    }

    func testCongestionCoarsensFastAndClampsToCoarse() {
        var c = ctrl(seed: 26)
        XCTAssertEqual(c.decide(congested: true), 29)
        XCTAssertEqual(c.decide(congested: true), 32)
        XCTAssertEqual(c.decide(congested: true), 35)
        XCTAssertEqual(c.decide(congested: true), 38)
        XCTAssertEqual(c.decide(congested: true), 40) // 41 clamped
        XCTAssertEqual(c.decide(congested: true), 40)
    }

    func testCleanSharpensOneStepPerIntervalAndClampsToSharp() {
        var c = ctrl(seed: 40)
        XCTAssertEqual(c.decide(congested: false), 40)
        XCTAssertEqual(c.decide(congested: false), 40)
        XCTAssertEqual(c.decide(congested: false), 40)
        XCTAssertEqual(c.decide(congested: false), 39) // 4th clean → −1
        for _ in 0..<3 { XCTAssertEqual(c.decide(congested: false), 39) }
        XCTAssertEqual(c.decide(congested: false), 38)
        for _ in 0..<200 { _ = c.decide(congested: false) }
        XCTAssertEqual(c.q, 26) // clamps at sharp
    }

    func testAIMDAsymmetry() {
        var c = ctrl(seed: 26)
        _ = c.decide(congested: true) // +3 → 29
        XCTAssertEqual(c.q, 29)
        for _ in 0..<3 { _ = c.decide(congested: false) }
        XCTAssertEqual(c.q, 29, "3 clean < interval recovers nothing")
    }

    func testCongestionResetsCleanStreak() {
        var c = ctrl(seed: 30)
        _ = c.decide(congested: false)
        _ = c.decide(congested: false)
        _ = c.decide(congested: true) // → 33, streak reset
        XCTAssertEqual(c.q, 33)
        _ = c.decide(congested: false)
        _ = c.decide(congested: false)
        _ = c.decide(congested: false)
        XCTAssertEqual(c.q, 33, "clean streak restarted after congestion")
        XCTAssertEqual(c.decide(congested: false), 32)
    }

    func testSanitizesHostileBounds() {
        let c = QPController(qSharp: 99, qCoarse: 5, upStep: 0, downInterval: 0, seedQ: 30)
        // qSharp 99→51, qCoarse→51, seed clamped to 51; upStep/downInterval floored at 1.
        XCTAssertEqual(c.q, 51)
        var m = c
        XCTAssertEqual(m.decide(congested: false), 51, "downInterval 1 ⇒ sharpen attempt, but already at sharp=51")
    }
}
