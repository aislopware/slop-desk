import XCTest
@testable import SlopDeskVideoHost

/// Exhaustive tests for the PURE static-frame suppression rule. No pixel buffers, no hashing, no
/// SCStream — only the boolean decision, so this runs headlessly under `swift test`. The single
/// load-bearing property is "never suppress a forced obligation": any one forced flag (or the first
/// frame, or a non-equal hash) must force `shouldSuppress == false`.
final class StaticFrameSuppressionDeciderTests: XCTestCase {
    private let decider = StaticFrameSuppressionDecider()

    /// The one and only case that suppresses: pixels unchanged, not the first frame, every
    /// obligation clear.
    func testSuppressesOnlyWhenDuplicateAndNoObligation() {
        XCTAssertTrue(
            decider.shouldSuppress(
                hashEqualToLast: true,
                isFirstFrame: false,
                forcedKeyframePending: false,
                recoveryPending: false,
                heartbeatDue: false,
                ltrRefreshDue: false,
                selfHealDue: false,
            ),
            "a pixel-identical duplicate with no forced obligation must be suppressed",
        )
    }

    /// A changed (or unknown) hash is never suppressed, regardless of obligations.
    func testNonEqualHashNeverSuppressed() {
        XCTAssertFalse(
            decider.shouldSuppress(
                hashEqualToLast: false,
                isFirstFrame: false,
                forcedKeyframePending: false,
                recoveryPending: false,
                heartbeatDue: false,
                ltrRefreshDue: false,
                selfHealDue: false,
            ),
            "a changed hash must always be encoded",
        )
    }

    /// The first frame is never suppressed even if its hash happens to equal the (uninitialised)
    /// last hash — the client needs the opening keyframe.
    func testFirstFrameNeverSuppressed() {
        XCTAssertFalse(
            decider.shouldSuppress(
                hashEqualToLast: true,
                isFirstFrame: true,
                forcedKeyframePending: false,
                recoveryPending: false,
                heartbeatDue: false,
                ltrRefreshDue: false,
                selfHealDue: false,
            ),
            "the first frame must always be encoded",
        )
    }

    /// THE invariant, exhaustively: for a pixel-identical, non-first frame, setting ANY single
    /// forced-obligation flag must flip the result to "encode" (never suppress).
    func testAnyForcedObligationPreventsSuppression() {
        // Each closure sets exactly ONE obligation flag true; all must yield `false`.
        let setters: [(String, (inout [Bool]) -> Void)] = [
            ("forcedKeyframePending", { $0[0] = true }),
            ("recoveryPending", { $0[1] = true }),
            ("heartbeatDue", { $0[2] = true }),
            ("ltrRefreshDue", { $0[3] = true }),
            ("selfHealDue", { $0[4] = true }),
        ]
        for (name, set) in setters {
            var flags = [false, false, false, false, false]
            set(&flags)
            XCTAssertFalse(
                decider.shouldSuppress(
                    hashEqualToLast: true,
                    isFirstFrame: false,
                    forcedKeyframePending: flags[0],
                    recoveryPending: flags[1],
                    heartbeatDue: flags[2],
                    ltrRefreshDue: flags[3],
                    selfHealDue: flags[4],
                ),
                "obligation \(name) set ⇒ must encode (never suppress)",
            )
        }
    }

    /// Brute-force the full truth table over all 7 boolean inputs (128 combinations) against an
    /// independent reference predicate, so no combination can silently regress.
    func testFullTruthTableMatchesReference() {
        for bits in 0..<128 {
            let hashEqual = bits & 0b0000001 != 0
            let first = bits & 0b0000010 != 0
            let kf = bits & 0b0000100 != 0
            let rec = bits & 0b0001000 != 0
            let hb = bits & 0b0010000 != 0
            let ltr = bits & 0b0100000 != 0
            let heal = bits & 0b1000000 != 0

            let expected = hashEqual && !first && !kf && !rec && !hb && !ltr && !heal
            XCTAssertEqual(
                decider.shouldSuppress(
                    hashEqualToLast: hashEqual,
                    isFirstFrame: first,
                    forcedKeyframePending: kf,
                    recoveryPending: rec,
                    heartbeatDue: hb,
                    ltrRefreshDue: ltr,
                    selfHealDue: heal,
                ),
                expected,
                "truth-table mismatch at bits=\(bits)",
            )
        }
    }
}
