import XCTest
@testable import AislopdeskVideoProtocol

/// Component 5 (recovery-redundancy, 2026-06-11): the three pure types that remove the
/// request-loss freeze tail — `RecoveryRequestRedundancy` (3× spaced byte-identical sends + the
/// before/after freeze math), the `RecoveryPolicy` loss-adaptive (halved) escalation clock, and
/// the `LossObservationWindow` predicate gating it. All headless (no transport / wall clock).
final class RecoveryRedundancyPolicyTests: XCTestCase {
    // MARK: RecoveryRequestRedundancy — offsets + clamps

    func testSendOffsetsForThreeCopies() {
        let r = RecoveryRequestRedundancy(copies: 3, spacing: 0.005)
        XCTAssertEqual(r.sendOffsets.count, 3)
        XCTAssertEqual(r.sendOffsets[0], 0, accuracy: 1e-12)
        XCTAssertEqual(r.sendOffsets[1], 0.005, accuracy: 1e-12)
        XCTAssertEqual(r.sendOffsets[2], 0.010, accuracy: 1e-12)
    }

    func testCopiesClampLowAndHigh() {
        XCTAssertEqual(RecoveryRequestRedundancy(copies: 0).copies, 1, "0 clamps up to 1 (today's single send)")
        XCTAssertEqual(RecoveryRequestRedundancy(copies: -3).copies, 1)
        XCTAssertEqual(RecoveryRequestRedundancy(copies: 9).copies, 5, "9 clamps down to 5")
        XCTAssertEqual(RecoveryRequestRedundancy(copies: 1).sendOffsets, [0], "copies=1 ⇒ single immediate send")
    }

    func testDefaultsAreThreeCopiesThreeMs() throws {
        let r = RecoveryRequestRedundancy()
        XCTAssertEqual(r.copies, 3)
        XCTAssertEqual(r.spacing, 0.003, accuracy: 1e-12)
        // Total spread must stay ≤ HALF the host dedup window (25 ms) so all copies dedup to one
        // even with reorder skew; the cross-side coupling at every legal copies count is pinned in
        // RecoveryRequestDeduperTests.testRedundancySpreadVsDedupWindowCouplingAtDefaults (the host
        // window constant lives in AislopdeskVideoHost, unreachable from this leaf target).
        XCTAssertLessThanOrEqual(try XCTUnwrap(r.sendOffsets.last), 0.025 / 2)
    }

    // MARK: RecoveryRequestRedundancy — pⁿ math

    func testAllCopiesLostProbability() {
        XCTAssertEqual(
            RecoveryRequestRedundancy.allCopiesLostProbability(perDatagramLoss: 0.09, copies: 3),
            7.29e-4,
            accuracy: 1e-9,
            "burst loss 9% → request lost drops 0.09 → 7.29e-4",
        )
        XCTAssertEqual(
            RecoveryRequestRedundancy.allCopiesLostProbability(perDatagramLoss: 0.42, copies: 1),
            0.42,
            accuracy: 1e-12,
            "(p, 1) = p — copies=1 is exactly today",
        )
        XCTAssertEqual(RecoveryRequestRedundancy.allCopiesLostProbability(perDatagramLoss: 0.0, copies: 4), 0.0)
        XCTAssertEqual(RecoveryRequestRedundancy.allCopiesLostProbability(perDatagramLoss: 1.0, copies: 4), 1.0)
        // Out-of-range p clamps to [0, 1] (never a negative/exploding probability).
        XCTAssertEqual(RecoveryRequestRedundancy.allCopiesLostProbability(perDatagramLoss: -0.5, copies: 3), 0.0)
        XCTAssertEqual(RecoveryRequestRedundancy.allCopiesLostProbability(perDatagramLoss: 1.5, copies: 3), 1.0)
    }

    /// THE before/after freeze-time assertion: at p=5% and a 100 ms escalation delay, a single
    /// send leaks 5 ms of expected freeze per loss event; 3 copies leak 12.5 µs — 400× less.
    func testExpectedRequestLossFreezeBeforeAfter() {
        let before = RecoveryRequestRedundancy.expectedRequestLossFreeze(
            perDatagramLoss: 0.05,
            copies: 1,
            escalationDelay: 0.1,
        )
        let after = RecoveryRequestRedundancy.expectedRequestLossFreeze(
            perDatagramLoss: 0.05,
            copies: 3,
            escalationDelay: 0.1,
        )
        XCTAssertEqual(before, 0.005, accuracy: 1e-12) // 5 ms
        XCTAssertEqual(after, 1.25e-5, accuracy: 1e-12) // 12.5 µs
        XCTAssertEqual(before / after, 400, accuracy: 1e-6)
    }

    // MARK: RecoveryPolicy — loss-adaptive escalation clock

    /// `observingLoss: false` must be EXACTLY the legacy 2-arg behaviour at every sampled point
    /// (the default path is byte-identical to today — no floor, 2·RTT).
    func testObservingLossFalseEquivalentToLegacyTwoArg() {
        let policy = RecoveryPolicy()
        for elapsed in stride(from: 0.0, through: 0.3, by: 0.007) {
            for rtt in [0.005, 0.01, 0.05, 0.1, 0.25] {
                XCTAssertEqual(
                    policy.shouldEscalateToIDR(elapsedSinceRequest: elapsed, rtt: rtt, observingLoss: false),
                    policy.shouldEscalateToIDR(elapsedSinceRequest: elapsed, rtt: rtt),
                    "divergence at elapsed=\(elapsed) rtt=\(rtt)",
                )
            }
        }
    }

    /// FIX 3 (2026-06-11): the lossy deadline is `max(1·RTT, 60 ms, 1.5·RTT)` — at rtt=50 ms the
    /// 1.5·RTT term dominates (75 ms), still strictly faster than the normal 2·RTT (100 ms).
    func testLossyClockFiresAtFloorOfOneAndAHalfRTT() {
        let policy = RecoveryPolicy()
        // Sample points sit just off the exact 75 ms boundary (1.5 × 0.05 is not FP-exact).
        XCTAssertFalse(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.0749, rtt: 0.05, observingLoss: true))
        XCTAssertTrue(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.0751, rtt: 0.05, observingLoss: true))
        // The normal clock at the same point still waits for 2·RTT.
        XCTAssertFalse(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.0751, rtt: 0.05, observingLoss: false))
        XCTAssertTrue(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.100, rtt: 0.05, observingLoss: false))
    }

    /// At rtt=10 ms the bare 1·RTT clock would escalate before any refresh could physically
    /// arrive — the 60 ms floor binds (escalates at 60 ms, not 10/15/30 ms).
    func testLossyFloorBindsAtLowRTT() {
        let policy = RecoveryPolicy()
        XCTAssertFalse(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.010, rtt: 0.01, observingLoss: true))
        XCTAssertFalse(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.059, rtt: 0.01, observingLoss: true))
        XCTAssertTrue(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.060, rtt: 0.01, observingLoss: true))
    }

    /// THE MEASURED DEFECT PIN (202 requestIDR vs 100 LTR refreshes): at rtt=20 ms — the live
    /// path's band — the loss-state-halved deadline NEVER drops below 60 ms (an LTR response
    /// needs host encode + flight + decode ≈ 40-60 ms; the old max(1·RTT, 30 ms) = 30 ms beat it).
    func testLossyDeadlineNeverBelow60msAtRtt20() {
        let policy = RecoveryPolicy()
        for elapsed in stride(from: 0.0, to: 0.060, by: 0.001) {
            XCTAssertFalse(
                policy.shouldEscalateToIDR(elapsedSinceRequest: elapsed, rtt: 0.02, observingLoss: true),
                "must not escalate at \(Int(elapsed * 1000)) ms (< the 60 ms floor)",
            )
        }
        XCTAssertTrue(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.060, rtt: 0.02, observingLoss: true))
    }

    /// The NORMAL (non-lossy) path has NO floor: at a tiny RTT it escalates at 2·RTT even below
    /// the lossy floor — byte-identical to the pre-component-5 policy.
    func testNormalPathHasNoFloor() {
        let policy = RecoveryPolicy()
        XCTAssertTrue(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.012, rtt: 0.006, observingLoss: false))
        XCTAssertFalse(policy.shouldEscalateToIDR(elapsedSinceRequest: 0.011, rtt: 0.006, observingLoss: false))
    }

    func testPolicyDefaults() {
        let policy = RecoveryPolicy()
        XCTAssertEqual(policy.idrTimeoutRTTMultiple, 2.0)
        XCTAssertEqual(policy.lossyIdrTimeoutRTTMultiple, 1.0)
        XCTAssertEqual(policy.lossyEscalationFloor, 0.06)
        XCTAssertEqual(policy.lossyEscalationFloorRTTMultiple, 1.5)
    }

    /// `AISLOPDESK_ESCALATION_FLOOR_MS` env resolution: default 60 ms, clamp 20...500,
    /// absent/garbage/out-of-band → default.
    func testEscalationFloorEnvResolution() {
        XCTAssertEqual(RecoveryPolicy.escalationFloorSeconds(env: [:]), 0.06)
        XCTAssertEqual(RecoveryPolicy.escalationFloorSeconds(env: ["AISLOPDESK_ESCALATION_FLOOR_MS": "100"]), 0.1)
        XCTAssertEqual(RecoveryPolicy.escalationFloorSeconds(env: ["AISLOPDESK_ESCALATION_FLOOR_MS": "20"]), 0.02)
        XCTAssertEqual(RecoveryPolicy.escalationFloorSeconds(env: ["AISLOPDESK_ESCALATION_FLOOR_MS": "500"]), 0.5)
        XCTAssertEqual(
            RecoveryPolicy.escalationFloorSeconds(env: ["AISLOPDESK_ESCALATION_FLOOR_MS": "19"]),
            0.06,
            "below the clamp → default",
        )
        XCTAssertEqual(
            RecoveryPolicy.escalationFloorSeconds(env: ["AISLOPDESK_ESCALATION_FLOOR_MS": "501"]),
            0.06,
            "above the clamp → default",
        )
        XCTAssertEqual(RecoveryPolicy.escalationFloorSeconds(env: ["AISLOPDESK_ESCALATION_FLOOR_MS": "garbage"]), 0.06)
    }

    // MARK: LossObservationWindow — the loss-observing predicate

    func testZeroAndOneEventAreNotObservingLoss() {
        var w = LossObservationWindow()
        XCTAssertFalse(w.isObservingLoss(now: 10.0), "no events ⇒ false")
        w.noteEvent(now: 10.0)
        XCTAssertFalse(w.isObservingLoss(now: 10.1), "a lone baseline ~1% loss event keeps today's 2·RTT clock")
    }

    func testTwoEventsWithinWindowObserveLoss() {
        var w = LossObservationWindow()
        w.noteEvent(now: 10.0)
        w.noteEvent(now: 10.4)
        XCTAssertTrue(w.isObservingLoss(now: 10.5))
    }

    func testTwoEventsSpreadWiderThanWindowDoNot() {
        var w = LossObservationWindow()
        w.noteEvent(now: 10.0)
        w.noteEvent(now: 11.5)
        XCTAssertFalse(w.isObservingLoss(now: 11.5), "1.5 s apart — only the newer is inside the 1 s window")
    }

    func testObservationAgesOut() {
        var w = LossObservationWindow()
        w.noteEvent(now: 10.0)
        w.noteEvent(now: 10.1)
        XCTAssertTrue(w.isObservingLoss(now: 10.2))
        XCTAssertFalse(
            w.isObservingLoss(now: 11.2),
            "both events now older than the window ⇒ back to the conservative clock",
        )
    }

    func testCapacityDropsOldestKeepsNewest() {
        var w = LossObservationWindow(windowSeconds: 100, minEvents: 8, capacity: 8)
        // 9 events in-window: the oldest must be evicted, the newest 8 kept ⇒ still ≥ minEvents.
        for i in 0..<9 { w.noteEvent(now: Double(i) * 0.01) }
        XCTAssertTrue(w.isObservingLoss(now: 0.1), "newest 8 retained")
        // With minEvents=8 and capacity=8, dropping ONE of the newest 8 would flip it — prove the
        // ring kept exactly the newest by aging the window edge past the would-be-evicted slot.
        var w2 = LossObservationWindow(windowSeconds: 0.05, minEvents: 2, capacity: 2)
        w2.noteEvent(now: 0.00)
        w2.noteEvent(now: 0.01)
        w2.noteEvent(now: 0.02) // evicts 0.00
        XCTAssertTrue(w2.isObservingLoss(now: 0.05), "0.01 + 0.02 survive")
    }

    func testCustomMinEventsAndWindowHonored() {
        var w = LossObservationWindow(windowSeconds: 0.5, minEvents: 3, capacity: 8)
        w.noteEvent(now: 1.0)
        w.noteEvent(now: 1.1)
        XCTAssertFalse(w.isObservingLoss(now: 1.2), "2 < minEvents 3")
        w.noteEvent(now: 1.2)
        XCTAssertTrue(w.isObservingLoss(now: 1.2))
        XCTAssertFalse(w.isObservingLoss(now: 1.6), "0.5 s window: the 1.0 event aged out ⇒ 2 remain < 3")
    }
}
