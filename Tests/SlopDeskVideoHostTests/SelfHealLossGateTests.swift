#if os(macOS)
import XCTest
@testable import SlopDeskVideoHost

/// PURE self-heal cadence decision (``WindowCapturer/shouldSelfHeal``). Pins the clean-link loss-gate the
/// Parsec RE motivated: with the gate OFF the every-Kth ``ForceLTRRefresh`` fires exactly as today
/// (byte-identical); with the gate ON it is SUPPRESSED on a loss-free link and re-arms the instant the
/// pushed loss EWMA crosses the threshold — no CoreMedia/VideoToolbox, just the heal-vs-skip arithmetic.
final class SelfHealLossGateTests: XCTestCase {
    private let threshold = 0.005

    private func heal(
        _ counter: Int, _ every: Int, eligible: Bool = true,
        gated: Bool = false, loss: Double = 0,
    ) -> Bool {
        WindowCapturer.shouldSelfHeal(
            framesSinceAnchor: counter, healEvery: every, eligible: eligible,
            lossGated: gated, lossRate: loss, threshold: threshold,
        )
    }

    // GATE OFF (the default): heals whenever the counter has reached K and acks flow, for ANY loss value
    // (the loss terms are ignored) — the exact pre-gate cadence, byte-identical.
    func testGateOffHealsAtKRegardlessOfLoss() {
        for loss in [0.0, 0.004, 0.5, Double.infinity] {
            XCTAssertTrue(heal(30, 30, gated: false, loss: loss))
            XCTAssertTrue(heal(45, 30, gated: false, loss: loss))
        }
    }

    // Below the cadence, or with acks not flowing, or with healing disabled — never heals, gate on or off.
    func testBaseCadencePreconditions() {
        for gated in [false, true] {
            XCTAssertFalse(heal(29, 30, gated: gated, loss: 0), "counter below K")
            XCTAssertFalse(heal(30, 30, eligible: false, gated: gated, loss: 1), "acks not flowing")
            XCTAssertFalse(heal(999, 0, gated: gated, loss: 1), "healEvery 0 = disabled")
        }
    }

    // GATE ON, clean link (loss < threshold): the every-Kth refresh is SUPPRESSED even though the counter
    // has reached K and acks flow — the whole point (no refresh doublet on a loss-0 link).
    func testGateOnCleanLinkSuppresses() {
        XCTAssertFalse(heal(30, 30, gated: true, loss: 0))
        XCTAssertFalse(heal(30, 30, gated: true, loss: 0.004)) // just under threshold
        XCTAssertFalse(heal(120, 30, gated: true, loss: 0)) // counter climbed well past K, still suppressed
    }

    // GATE ON, loss present (loss >= threshold): heals normally — the protection re-arms the instant loss
    // appears. Because the caller keeps advancing the counter while suppressed, the first lossy frame is
    // already past K, so healing fires immediately (modelled here by a counter well beyond K).
    func testGateOnLossyLinkHealsAndReArmsImmediately() {
        XCTAssertTrue(heal(30, 30, gated: true, loss: 0.005)) // exactly at threshold ⇒ armed
        XCTAssertTrue(heal(30, 30, gated: true, loss: 0.02))
        XCTAssertTrue(heal(200, 30, gated: true, loss: 0.01), "counter climbed while clean, first lossy frame heals")
    }

    // The load-bearing inversion: IDENTICAL (counter, K, eligible) with a clean-link loss → the gate flips
    // the decision. Off keeps healing; on suppresses. This is the entire behavioural delta of the lever.
    func testGateInvertsOnIdenticalCleanLinkInput() {
        XCTAssertTrue(heal(30, 30, gated: false, loss: 0.001), "gate off keeps the refresh")
        XCTAssertFalse(heal(30, 30, gated: true, loss: 0.001), "gate on drops it on the clean link")
    }

    // Threshold boundary: < threshold suppresses, >= threshold heals (the fail-toward-protection edge).
    func testThresholdBoundary() {
        XCTAssertFalse(heal(30, 30, gated: true, loss: threshold - 0.0001))
        XCTAssertTrue(heal(30, 30, gated: true, loss: threshold))
    }
}
#endif
