import XCTest
@testable import AislopdeskVideoProtocol

/// Differential parity: the Rust-backed `RecoveryPolicy.shouldEscalateToIDR` must equal the
/// former native escalation clock. The existing recovery tests pin the behaviour and re-run
/// through the Rust path; this adds an inline native oracle and fuzzes the public API across a
/// wide grid (elapsed × rtt × observingLoss × policy multiples). `lossyEscalationFloor` stays
/// resolved Swift-side and is part of the policy instance.
final class RustRecoveryPolicyParityTests: XCTestCase {
    private func native(
        _ p: RecoveryPolicy, _ elapsed: Double, _ rtt: Double, _ observing: Bool,
    ) -> Bool {
        let multiple = observing ? p.lossyIdrTimeoutRTTMultiple : p.idrTimeoutRTTMultiple
        let deadline: Double
        if observing {
            let floor = max(p.lossyEscalationFloor, p.lossyEscalationFloorRTTMultiple * rtt)
            deadline = max(multiple * rtt, floor)
        } else {
            deadline = multiple * rtt
        }
        return elapsed >= deadline
    }

    func testDefaultPolicyParityFuzz() {
        let p = RecoveryPolicy() // production defaults
        var rng = SystemRandomNumberGenerator()
        var grid: [Double] = []
        var e = 0.0
        while e <= 0.35 { grid.append(e)
            e += 0.001
        }
        for _ in 0..<3000 { grid.append(Double.random(in: 0...0.5, using: &rng)) }
        for elapsed in grid {
            for rtt in [0.0, 0.003, 0.006, 0.01, 0.025, 0.05, 0.1, 0.25] {
                for observing in [false, true] {
                    XCTAssertEqual(
                        p.shouldEscalateToIDR(elapsedSinceRequest: elapsed, rtt: rtt, observingLoss: observing),
                        native(p, elapsed, rtt, observing),
                        "elapsed \(elapsed) rtt \(rtt) observing \(observing)",
                    )
                }
            }
        }
    }

    func testVariedPolicyMultiplesParityFuzz() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let p = RecoveryPolicy(
                idrTimeoutRTTMultiple: Double.random(in: 0.5...4, using: &rng),
                lossyIdrTimeoutRTTMultiple: Double.random(in: 0.5...4, using: &rng),
                lossyEscalationFloor: Double.random(in: 0...0.2, using: &rng),
                lossyEscalationFloorRTTMultiple: Double.random(in: 0...3, using: &rng),
            )
            let elapsed = Double.random(in: 0...0.5, using: &rng)
            let rtt = Double.random(in: 0...0.3, using: &rng)
            let observing = Bool.random(using: &rng)
            XCTAssertEqual(
                p.shouldEscalateToIDR(elapsedSinceRequest: elapsed, rtt: rtt, observingLoss: observing),
                native(p, elapsed, rtt, observing),
            )
        }
    }

    func testTwoArgConvenienceUsesNoLossPath() {
        let p = RecoveryPolicy()
        // The 2-arg form is observingLoss:false — must match the explicit no-loss call.
        for rtt in [0.01, 0.05, 0.1] {
            for elapsed in [0.0, rtt, 2 * rtt, 3 * rtt] {
                XCTAssertEqual(
                    p.shouldEscalateToIDR(elapsedSinceRequest: elapsed, rtt: rtt),
                    p.shouldEscalateToIDR(elapsedSinceRequest: elapsed, rtt: rtt, observingLoss: false),
                )
            }
        }
    }
}
