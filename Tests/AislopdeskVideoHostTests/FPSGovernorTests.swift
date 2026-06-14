import XCTest
@testable import AislopdeskVideoHost

/// FPS GOVERNOR (2026-06-11): the regular-cadence content/congestion-adaptive fps policy that
/// replaced the retired `AdaptiveFPSController` alternating skip. Pure value types — ladder +
/// asymmetric hysteresis + budget test (`FPSGovernor`), schedule-anchored admit
/// (`EncodeCadenceGate`), time-equivalent self-heal K (`SelfHealCadence`). All tests assume the
/// default env tunables (warmup 10, downN 3, downHold 8, upN 60, headroom 1.2, minFps 15).
final class FPSGovernorTests: XCTestCase {
    // MARK: Ladder

    func testLadderBase60() {
        XCTAssertEqual(FPSGovernor.ladder(baseFps: 60), [60, 30, 20, 15])
    }

    func testLadderBase30DropsSubMinRungs() {
        // 30/2=15 stays (== minFps); 30/3=10 and 30/4=7 fall below the 15 floor → dropped.
        XCTAssertEqual(FPSGovernor.ladder(baseFps: 30), [30, 15])
    }

    func testLadderNeverEmptyAlwaysContainsBase() {
        // A base below minFps still yields a one-rung ladder (the base itself).
        XCTAssertEqual(FPSGovernor.ladder(baseFps: 10), [10])
        XCTAssertEqual(FPSGovernor(baseFps: 10).currentFps, 10)
    }

    // MARK: Warmup + unseeded guards

    func testNoStepDuringWarmupEvenOverBudgetAndCongested() {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 1_000_000, isAnchor: false) // offered ≈ 480 Mbps at 60
        for _ in 0..<(FPSGovernor.warmupTicks - 1) {
            XCTAssertEqual(gov.onTick(targetBps: 10_000_000, congested: true), 60)
        }
        XCTAssertEqual(gov.currentFps, 60, "no action inside the warmup window")
    }

    func testUnseededEWMANeverSteps() {
        var gov = FPSGovernor(baseFps: 60)
        for _ in 0..<100 {
            XCTAssertEqual(
                gov.onTick(targetBps: 1, congested: true),
                60,
                "bytesPerFrameEWMA == 0 (no encoded frame folded) must never act",
            )
        }
    }

    // MARK: noteEncodedFrame (EWMA fold)

    func testAnchorFramesExcludedFromEWMA() {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 500_000, isAnchor: true) // keyframe/crisp: excluded
        XCTAssertEqual(gov.bytesPerFrameEWMA, 0, "anchors are episodic outliers — never folded")
        gov.noteEncodedFrame(bytes: 10000, isAnchor: false) // first non-anchor seeds exactly
        XCTAssertEqual(gov.bytesPerFrameEWMA, 10000)
        gov.noteEncodedFrame(bytes: 500_000, isAnchor: true)
        XCTAssertEqual(gov.bytesPerFrameEWMA, 10000, "a later anchor still does not move the EWMA")
    }

    func testEWMAAlphaConvergence() {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 10000, isAnchor: false)
        gov.noteEncodedFrame(bytes: 20000, isAnchor: false)
        // 10000 × 0.875 + 20000 × 0.125 = 11250 (alpha 0.125 — the loss-EWMA discipline).
        XCTAssertEqual(gov.bytesPerFrameEWMA, 11250, accuracy: 1e-9)
        // Converges toward a sustained new level.
        for _ in 0..<60 { gov.noteEncodedFrame(bytes: 20000, isAnchor: false) }
        XCTAssertEqual(gov.bytesPerFrameEWMA, 20000, accuracy: 20)
        // Zero/negative bytes are ignored (defensive).
        gov.noteEncodedFrame(bytes: 0, isAnchor: false)
        XCTAssertEqual(gov.bytesPerFrameEWMA, 20000, accuracy: 20)
    }

    // MARK: Step-down requires BOTH arms (over-budget AND congested)

    func testOverBudgetWithoutCongestionNeverStepsDown() {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 1_000_000, isAnchor: false)
        for _ in 0..<100 {
            XCTAssertEqual(
                gov.onTick(targetBps: 10_000_000, congested: false),
                60,
                "static/heavy content on a CLEAN link never reduces fps (input-latency rule)",
            )
        }
        XCTAssertEqual(gov.cleanRun, 0, "over-budget-without-congestion freezes the clean run too")
    }

    func testCongestionWithoutOverBudgetNeverStepsDown() {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 1000, isAnchor: false) // offered ≈ 480 kbps — tiny
        for _ in 0..<100 {
            XCTAssertEqual(
                gov.onTick(targetBps: 10_000_000, congested: true),
                60,
                "congestion alone (stream already fits) must not sacrifice fps",
            )
        }
    }

    // MARK: Step-down speed + one-rung-per-window spacing

    func testStepDownAfterStreakThenHoldWindowSpacesRungs() throws {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 1_000_000, isAnchor: false)
        var stepTicks: [Int: Int] = [:] // fps → tick it was reached
        var fps = 60
        for _ in 0..<40 {
            let next = gov.onTick(targetBps: 10_000_000, congested: true)
            if next != fps {
                XCTAssertEqual(
                    try XCTUnwrap(FPSGovernor.ladder(baseFps: 60).firstIndex(of: next)),
                    try XCTUnwrap(FPSGovernor.ladder(baseFps: 60).firstIndex(of: fps)) + 1,
                    "exactly ONE rung per step — never 60→15 in one window",
                )
                stepTicks[next] = gov.ticks
                fps = next
            }
        }
        // First step: warmup(10) + the 3rd over-budget+congested acting tick = tick 12.
        XCTAssertEqual(stepTicks[30], FPSGovernor.warmupTicks + FPSGovernor.stepDownTicks - 1)
        // Subsequent rungs are spaced by the hold window (8 ticks ≈ 400 ms), not by the streak.
        XCTAssertEqual(try XCTUnwrap(stepTicks[20]) - stepTicks[30]!, FPSGovernor.stepDownHoldTicks)
        XCTAssertEqual(try XCTUnwrap(stepTicks[15]) - stepTicks[20]!, FPSGovernor.stepDownHoldTicks)
        XCTAssertEqual(gov.currentFps, 15, "ladder floor — never below minFps")
        XCTAssertEqual(gov.onTick(targetBps: 10_000_000, congested: true), 15, "no rung below the floor")
    }

    func testOverBudgetRunResetsOnCleanTick() {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 1_000_000, isAnchor: false)
        for _ in 0..<FPSGovernor.warmupTicks { _ = gov.onTick(
            targetBps: 1_000_000_000,
            congested: false,
        ) } // warmup, clean
        _ = gov.onTick(targetBps: 10_000_000, congested: true)
        _ = gov.onTick(targetBps: 10_000_000, congested: true)
        XCTAssertEqual(gov.overBudgetRun, 2)
        _ = gov.onTick(targetBps: 1_000_000_000, congested: false) // fits → clean → streak resets
        XCTAssertEqual(gov.overBudgetRun, 0)
        XCTAssertEqual(gov.currentFps, 60, "two-of-three over-budget ticks never step (streak must be consecutive)")
    }

    // MARK: Step-up (slow, fit-gated, one rung per run)

    /// Drives a governor down to 20 fps with a heavy EWMA, then re-folds a light EWMA for the climb.
    private func governorAt20() -> FPSGovernor {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 1_000_000, isAnchor: false)
        while gov.currentFps != 20 { _ = gov.onTick(targetBps: 10_000_000, congested: true) }
        // Content lightens: re-converge the EWMA to ~1 KB frames (≈ 240 kbps at 60 fps).
        for _ in 0..<200 { gov.noteEncodedFrame(bytes: 1000, isAnchor: false) }
        return gov
    }

    func testStepUpRequiresCleanRunAndProjectedFitOneRungPerRun() {
        var gov = governorAt20()
        var fpsTrail: [Int] = []
        var fps = gov.currentFps
        for _ in 0..<(FPSGovernor.stepUpTicks * 2 + 2) {
            let next = gov.onTick(targetBps: 10_000_000, congested: false)
            if next != fps { fpsTrail.append(next)
                fps = next
            }
        }
        XCTAssertEqual(fpsTrail, [30, 60], "one rung per clean run: 20→30 then 30→60, never a jump")
        XCTAssertEqual(gov.currentFps, 60)
        for _ in 0..<(FPSGovernor.stepUpTicks + 1) {
            XCTAssertEqual(gov.onTick(targetBps: 10_000_000, congested: false), 60, "never exceeds baseFps")
        }
    }

    func testStepUpBlockedByStrictProjectedFit() {
        var gov = FPSGovernor(baseFps: 60)
        gov.noteEncodedFrame(bytes: 1_000_000, isAnchor: false)
        while gov.currentFps != 30 { _ = gov.onTick(targetBps: 10_000_000, congested: true) }
        // EWMA → 10 KB: offered at 30 = 2.4 Mbps (fits 3 Mbps × 1.2 headroom → clean), but the
        // PROJECTED 60 fps load = 4.8 Mbps > 3 Mbps target (strict fit, NO headroom) → blocked.
        for _ in 0..<200 { gov.noteEncodedFrame(bytes: 10000, isAnchor: false) }
        for _ in 0..<(FPSGovernor.stepUpTicks * 3) {
            XCTAssertEqual(
                gov.onTick(targetBps: 3_000_000, congested: false),
                30,
                "clean run alone is not enough — the next rung must PROJECT under target",
            )
        }
        XCTAssertGreaterThanOrEqual(
            gov.cleanRun,
            FPSGovernor.stepUpTicks,
            "the run keeps accruing; only the fit blocks",
        )
    }

    func testOverBudgetWithoutCongestionFreezesCleanRun() {
        var gov = governorAt20()
        for _ in 0..<30 { _ = gov.onTick(targetBps: 10_000_000, congested: false) }
        XCTAssertEqual(gov.cleanRun, 30)
        // One content-heavy-on-clean-link tick (over budget, not congested): freeze, not clean.
        for _ in 0..<200 { gov.noteEncodedFrame(bytes: 1_000_000, isAnchor: false) }
        _ = gov.onTick(targetBps: 10_000_000, congested: false)
        XCTAssertEqual(gov.cleanRun, 0, "over-budget-without-congestion re-arms the step-up clock")
        XCTAssertEqual(gov.currentFps, 20, "…and does not step down either")
    }

    // MARK: congestionEvidence (the step-down AND-gate's second arm)

    func testCongestionEvidenceABRBelowCeiling() {
        XCTAssertTrue(FPSGovernor.congestionEvidence(
            lastLossSample: 0,
            smoothedRTTMillis: 10,
            minRTTMillis: 10,
            abrCurrent: 5_000_000,
            abrCeiling: 10_000_000,
        ))
        XCTAssertFalse(
            FPSGovernor.congestionEvidence(
                lastLossSample: 0,
                smoothedRTTMillis: 10,
                minRTTMillis: 10,
                abrCurrent: 10_000_000,
                abrCeiling: 10_000_000,
            ),
            "ABR AT the ceiling is not congestion evidence",
        )
    }

    func testCongestionEvidenceRawLossOverThreshold() {
        XCTAssertTrue(FPSGovernor.congestionEvidence(
            lastLossSample: LiveCongestionController.lossThreshold + 0.01,
            smoothedRTTMillis: 10,
            minRTTMillis: 10,
            abrCurrent: nil,
            abrCeiling: nil,
        ))
        XCTAssertFalse(
            FPSGovernor.congestionEvidence(
                lastLossSample: LiveCongestionController.lossThreshold,
                smoothedRTTMillis: 10,
                minRTTMillis: 10,
                abrCurrent: nil,
                abrCeiling: nil,
            ),
            "at-threshold loss does not trip (strict >, matching the ABR)",
        )
    }

    func testCongestionEvidenceRTTInflation() {
        // minRTT 10 ⇒ slack = max(15, 0.75×10) = 15 ⇒ needs smoothed > 12.5 AND > 25.
        XCTAssertTrue(FPSGovernor.congestionEvidence(
            lastLossSample: 0,
            smoothedRTTMillis: 30,
            minRTTMillis: 10,
            abrCurrent: nil,
            abrCeiling: nil,
        ))
        XCTAssertFalse(
            FPSGovernor.congestionEvidence(
                lastLossSample: 0,
                smoothedRTTMillis: 20,
                minRTTMillis: 10,
                abrCurrent: nil,
                abrCeiling: nil,
            ),
            "past the factor but inside the absolute slack = LAN wobble, not congestion",
        )
        XCTAssertFalse(FPSGovernor.congestionEvidence(
            lastLossSample: 0,
            smoothedRTTMillis: 11,
            minRTTMillis: 10,
            abrCurrent: nil,
            abrCeiling: nil,
        ))
    }

    func testCongestionEvidenceInfiniteMinRTTFallsBackToOtherArms() {
        XCTAssertFalse(
            FPSGovernor.congestionEvidence(
                lastLossSample: 0,
                smoothedRTTMillis: 100,
                minRTTMillis: .infinity,
                abrCurrent: nil,
                abrCeiling: nil,
            ),
            "no RTT baseline (telemetry off) ⇒ the RTT arm can never fire",
        )
        XCTAssertTrue(
            FPSGovernor.congestionEvidence(
                lastLossSample: 0.05,
                smoothedRTTMillis: 100,
                minRTTMillis: .infinity,
                abrCurrent: nil,
                abrCeiling: nil,
            ),
            "…but the loss arm still works",
        )
    }
}

/// The schedule-anchored regular-cadence admit gate (the governor's actuator — NOT the retired
/// alternating skip). Deliveries stay at the full capture rate; the gate admits every k-th slot
/// drift-free.
final class EncodeCadenceGateTests: XCTestCase {
    private let slot = 1.0 / 60.0 // delivery interval (60 fps content deliveries)
    private let tol = 0.5 / 120.0 // half a 120 Hz capture slot ≈ 4.17 ms

    func testInertWhenTargetIntervalNonPositive() {
        var gate = EncodeCadenceGate()
        for i in 0..<10 {
            XCTAssertTrue(gate.admit(
                now: Double(i) * slot,
                targetIntervalSeconds: 0,
                toleranceSeconds: tol,
                forced: false,
            ))
            XCTAssertTrue(gate.admit(
                now: Double(i) * slot,
                targetIntervalSeconds: -1,
                toleranceSeconds: tol,
                forced: false,
            ))
        }
    }

    func testFirstCallAdmitsAndAnchors() {
        var gate = EncodeCadenceGate()
        XCTAssertTrue(gate.admit(now: 100.0, targetIntervalSeconds: 1.0 / 30.0, toleranceSeconds: tol, forced: false))
        XCTAssertFalse(
            gate.admit(now: 100.0 + slot, targetIntervalSeconds: 1.0 / 30.0, toleranceSeconds: tol, forced: false),
            "the very next delivery slot is before the anchored due time",
        )
    }

    /// Deliveries every 16.7 ms with a 33.3 ms target admit exactly every 2nd, spacing exactly
    /// 33.3 ms; 20 fps → every 3rd; 15 fps → every 4th (the clean-divisor ladder property).
    func testRegularCadenceAtEveryLadderRung() {
        for (fps, expectStride) in [(30, 2), (20, 3), (15, 4)] {
            var gate = EncodeCadenceGate()
            var admittedSlots: [Int] = []
            for i in 0..<48 where gate.admit(
                now: Double(i) * slot,
                targetIntervalSeconds: 1.0 / Double(fps),
                toleranceSeconds: tol,
                forced: false,
            ) {
                admittedSlots.append(i)
            }
            XCTAssertGreaterThan(admittedSlots.count, 3)
            for pair in zip(admittedSlots, admittedSlots.dropFirst()) {
                XCTAssertEqual(
                    pair.1 - pair.0,
                    expectStride,
                    "\(fps) fps from 60 fps deliveries = every \(expectStride). slot, metronome-regular",
                )
            }
        }
    }

    func testArrivalJitterNeverSlipsASlotAndScheduleDoesNotDrift() {
        var gate = EncodeCadenceGate()
        let interval = 1.0 / 30.0
        var admitted: [Double] = []
        // ±4 ms deterministic jitter on every delivery — inside the half-slot tolerance.
        for i in 0..<60 {
            let jitter = (i.isMultiple(of: 2) ? -0.004 : 0.004)
            let now = Double(i) * slot + (i == 0 ? 0 : jitter)
            if gate.admit(now: now, targetIntervalSeconds: interval, toleranceSeconds: tol, forced: false) {
                admitted.append(Double(i) * slot) // nominal slot time — measures slot indices
            }
        }
        for pair in zip(admitted, admitted.dropFirst()) {
            XCTAssertEqual(
                pair.1 - pair.0,
                interval,
                accuracy: 1e-9,
                "every 2nd slot despite ±4 ms jitter — schedule-anchored, no drift",
            )
        }
    }

    func testForcedAlwaysAdmitsAndReanchors() {
        var gate = EncodeCadenceGate()
        let interval = 1.0 / 30.0
        XCTAssertTrue(gate.admit(now: 0, targetIntervalSeconds: interval, toleranceSeconds: tol, forced: false))
        // A forced frame on the very next slot (recovery latch) is ALWAYS admitted…
        XCTAssertTrue(gate.admit(now: slot, targetIntervalSeconds: interval, toleranceSeconds: tol, forced: true))
        // …and re-anchors: the following non-forced frame waits a FULL interval (regular around IDRs).
        XCTAssertFalse(gate.admit(now: 2 * slot, targetIntervalSeconds: interval, toleranceSeconds: tol, forced: false))
        XCTAssertTrue(gate.admit(now: 3 * slot, targetIntervalSeconds: interval, toleranceSeconds: tol, forced: false))
    }

    func testContentStallReanchorsWithoutBurstCatchUp() {
        var gate = EncodeCadenceGate()
        let interval = 1.0 / 30.0
        XCTAssertTrue(gate.admit(now: 0, targetIntervalSeconds: interval, toleranceSeconds: tol, forced: false))
        // Idle window: no deliveries for 500 ms. The resume delivery is admitted once and the
        // schedule re-anchors from NOW — the next slot is NOT admitted (no backlog burst).
        XCTAssertTrue(gate.admit(now: 0.5, targetIntervalSeconds: interval, toleranceSeconds: tol, forced: false))
        XCTAssertFalse(gate.admit(
            now: 0.5 + slot,
            targetIntervalSeconds: interval,
            toleranceSeconds: tol,
            forced: false,
        ))
        XCTAssertTrue(gate.admit(
            now: 0.5 + 2 * slot,
            targetIntervalSeconds: interval,
            toleranceSeconds: tol,
            forced: false,
        ))
    }

    /// GATED-TAIL FLUSH seam: a REJECTED admit exposes the schedule's next-due boundary
    /// (`nextDue`) so the capturer can arm the one-shot flush against it; rejections never move
    /// the boundary (repeated gated deliveries re-arm against the SAME slot); the flush firing AT
    /// the boundary is admitted and advances the schedule drift-free.
    func testRejectionExposesStableNextDueDeadline() {
        var gate = EncodeCadenceGate()
        let interval = 1.0 / 30.0
        XCTAssertEqual(gate.nextDue, 0, "unanchored before the first admit")
        XCTAssertTrue(gate.admit(now: 100.0, targetIntervalSeconds: interval, toleranceSeconds: tol, forced: false))
        XCTAssertEqual(gate.nextDue, 100.0 + interval, accuracy: 1e-9, "the first admit anchors the boundary")
        // Two gated deliveries inside the governed slot: both rejected, boundary UNMOVED.
        XCTAssertFalse(gate.admit(
            now: 100.0 + slot,
            targetIntervalSeconds: interval,
            toleranceSeconds: tol,
            forced: false,
        ))
        XCTAssertEqual(gate.nextDue, 100.0 + interval, accuracy: 1e-9, "a rejection must not move the boundary")
        XCTAssertFalse(gate.admit(
            now: 100.0 + 1.5 * slot,
            targetIntervalSeconds: interval,
            toleranceSeconds: tol,
            forced: false,
        ))
        XCTAssertEqual(gate.nextDue, 100.0 + interval, accuracy: 1e-9, "re-armed flush targets the SAME slot")
        // The one-shot fires AT the exposed boundary → admitted, schedule advances by one interval.
        XCTAssertTrue(gate.admit(
            now: gate.nextDue,
            targetIntervalSeconds: interval,
            toleranceSeconds: tol,
            forced: false,
        ))
        XCTAssertEqual(gate.nextDue, 100.0 + 2 * interval, accuracy: 1e-9, "the flush consumes the slot drift-free")
        // Inert gate (ungoverned): admits never consult the schedule and the anchor keeps its value.
        var inert = EncodeCadenceGate()
        XCTAssertTrue(inert.admit(now: 5.0, targetIntervalSeconds: 0, toleranceSeconds: tol, forced: false))
        XCTAssertEqual(inert.nextDue, 0, "an inert admit never anchors a boundary")
    }
}

/// Time-equivalent self-heal K at a governed fps: wall-clock heal latency stays ≈ constant.
final class SelfHealCadenceTests: XCTestCase {
    func testEffectiveEvery() {
        XCTAssertEqual(SelfHealCadence.effectiveEvery(baseEvery: 6, baseFps: 60, governedFps: 60), 6)
        XCTAssertEqual(SelfHealCadence.effectiveEvery(baseEvery: 6, baseFps: 60, governedFps: 30), 3)
        XCTAssertEqual(SelfHealCadence.effectiveEvery(baseEvery: 6, baseFps: 60, governedFps: 20), 2)
        XCTAssertEqual(SelfHealCadence.effectiveEvery(baseEvery: 6, baseFps: 60, governedFps: 15), 2, "clamped ≥ 2")
    }

    func testDisabledPassthroughAndDegenerateBase() {
        XCTAssertEqual(
            SelfHealCadence.effectiveEvery(baseEvery: 0, baseFps: 60, governedFps: 30),
            0,
            "AISLOPDESK_SELF_HEAL=0 stays disabled at every governed fps",
        )
        XCTAssertEqual(
            SelfHealCadence.effectiveEvery(baseEvery: 6, baseFps: 0, governedFps: 30),
            max(2, 6 * 30),
            "degenerate baseFps clamps to 1, never divides by zero",
        )
    }
}

#if canImport(VideoToolbox) && canImport(ScreenCaptureKit)
/// Pure-refactor regression guard for the capture-ceiling resolution that moved out of
/// `WindowCapturer.makeConfiguration` (the cadence gate's tolerance is half of this).
final class ResolveCaptureHzTests: XCTestCase {
    func testDefaultIsTwiceEncodeFpsCeilinged240() {
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: nil, fps: 60), 120)
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: nil, fps: 120), 240)
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: nil, fps: 200), 240)
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: nil, fps: 1), 2)
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: nil, fps: 0), 2, "fps clamps ≥ 1")
    }

    func testEnvOverrideClamps() {
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: "90", fps: 60), 90)
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: "1", fps: 60), 15, "floor 15")
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: "1000", fps: 60), 240, "ceiling 240")
        XCTAssertEqual(WindowCapturer.resolveCaptureHz(envValue: "abc", fps: 60), 120, "garbage env → default")
    }
}
#endif
