import XCTest
@testable import AislopdeskVideoClient

/// Component 4 (adaptive pacer depth): PURE virtual-clock tests of ``PacerDepthPolicy``.
/// v3 (2026-06-12): the depth ACTION (promote/demote) runs on NETWORK-late events
/// (``PacerDepthPolicy/noteNetworkLate(_:)`` — owd spikes from `OwdLateDetector`); the
/// present-gap classifier (late/idle/dense) is telemetry + diagnostics only. No Apple
/// frameworks touched; all time is injected seconds.
final class PacerDepthPolicyTests: XCTestCase {
    /// Drive `n` clean in-flow slots at `fps`: arrival + present at the same instant
    /// (the depth-1 present-on-arrival model), with 120 Hz re-show ticks in between.
    private func driveClean(
        _ dp: inout PacerDepthPolicy,
        from t: Double,
        frames: Int,
        fps: Double = 60,
        reshows: Bool = true,
    ) -> Double {
        var t = t
        var lastPresent = t
        for _ in 0..<frames {
            t += 1.0 / fps
            if reshows {
                var tick = lastPresent + 1.0 / 120.0
                while tick < t { dp.noteReshow(tick)
                    tick += 1.0 / 120.0
                }
            }
            dp.noteArrival(t)
            dp.notePresent(t)
            lastPresent = t
        }
        return t
    }

    /// One skipped 60fps content slot: a 33.3ms arrival+present gap (the dominant hitch shape).
    private func skipOneSlot(
        _ dp: inout PacerDepthPolicy,
        from t: Double,
    ) -> (t: Double, cls: PacerDepthPolicy.GapClass) {
        let t2 = t + 2.0 / 60.0
        dp.noteArrival(t2)
        return (t2, dp.notePresent(t2))
    }

    // MARK: Clean-link guarantees

    func testCleanSteady60fpsNeverLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        _ = driveClean(&dp, from: 0, frames: 600) // 10s
        let win = dp.drainCounters()
        XCTAssertEqual(win.lateFrames, 0)
        XCTAssertEqual(win.presentGaps, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    /// Locks the 28ms absolute floor for the CLASSIFIER (telemetry): at depth 2 with a 120Hz tick,
    /// presents can alternate 8.3/25ms around tick quantization while arrivals stay 60fps. The
    /// 25ms leg passes the gradient (25 ≥ 1.45×8.3) — ONLY the floor keeps it sub-late.
    func testTickQuantizationAlternationNeverLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var arrival = 0.0, present = 0.0
        for i in 0..<240 {
            arrival += 1.0 / 60.0
            dp.noteArrival(arrival)
            present += i.isMultiple(of: 2) ? 1.0 / 120.0 : 0.025
            XCTAssertNotEqual(dp.notePresent(present), .late, "tick-alternation gap must stay sub-late")
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    // MARK: v3 — present-gap lates are telemetry only (THE structural pinning fix)

    /// A genuine present-gap late still CLASSIFIES (diagnostics) but neither counts into
    /// `lateFrames` nor promotes — arrival gaps conflate network lateness with content cadence
    /// (the measured 2026-06-11 depth-2 pinning bug).
    func testPresentGapLateClassifiesButNeverCountsNorPromotes() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 130) // past the 2s promote warmup
        for _ in 0..<6 { // 6 genuine 33ms hitches, ~330ms apart
            let r = skipOneSlot(&dp, from: t)
            XCTAssertEqual(r.cls, .late, "classification stays (diagnostics)")
            t = driveClean(&dp, from: r.t, frames: 20)
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0, "present lates never count (v3)")
        XCTAssertEqual(dp.depth, 1, "present lates never promote (v3)")
    }

    /// REGRESSION — the measured 2026-06-12 pinning shape, inverted: promoted depth must DEMOTE
    /// through a stretch whose every present gap classifies late (sub-cadence content under a
    /// stale hint), because the dwell evaluates NETWORK lates only.
    func testSubCadenceContentCannotPinDepth() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 130)
        // Promote via two genuine network lates.
        dp.noteNetworkLate(t)
        dp.noteNetworkLate(t + 0.2)
        XCTAssertEqual(dp.depth, 2)
        // 10s of ~25fps content under the 60fps hint: gaps are 40ms — past the late boundary,
        // dense enough to classify — yet zero network lates arrive.
        dp.setIntervalHint(1.0 / 60.0)
        for _ in 0..<250 {
            t += 0.040
            dp.noteArrival(t)
            dp.notePresent(t)
        }
        XCTAssertEqual(dp.depth, 1, "MUST demote — content cadence cannot hold the boost (v3)")
    }

    // MARK: Network-late promotion

    func testSingleNetworkLateNeverPromotes() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        let t = driveClean(&dp, from: 0, frames: 130)
        dp.noteNetworkLate(t)
        XCTAssertEqual(dp.depth, 1, "one late never promotes")
        XCTAssertEqual(dp.drainCounters().lateFrames, 1, "but it counts (telemetry)")
    }

    func testTwoNetworkLatesWithinWindowPromote() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        let t = driveClean(&dp, from: 0, frames: 130) // ~2.2s — past the 2s promote warmup
        dp.noteNetworkLate(t)
        dp.noteNetworkLate(t + 0.6) // inside the 1s pairing window
        XCTAssertEqual(dp.depth, 2, "2nd late within the 1s window promotes")
    }

    func testTwoNetworkLatesOutsideWindowNoPromote() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 130)
        dp.noteNetworkLate(t)
        t = driveClean(&dp, from: t, frames: 72) // 1.2s of clean flow
        dp.noteNetworkLate(t)
        XCTAssertEqual(dp.depth, 1, "lates 1.2s apart never pair inside the 1s window")
    }

    func testBurstPromotesWithinBudget() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 180) // 3s clean
        let onset = t
        var promotedAt: Double?
        // Wi-Fi burst: an owd spike every ~333ms while flow continues.
        for i in 0..<600 {
            t += 1.0 / 60.0
            dp.noteArrival(t)
            dp.notePresent(t)
            if i.isMultiple(of: 20) { dp.noteNetworkLate(t) }
            if dp.depth == 2, promotedAt == nil { promotedAt = t }
        }
        guard let promotedAt else { XCTFail("never promoted under a spiking burst")
            return
        }
        XCTAssertLessThanOrEqual(promotedAt - onset, 1.5, "promotion must land ≤1.5s after onset")
    }

    func testBurstHoldsDepthThroughout() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 130)
        // 10s of network lates spaced 350-650ms apart (intra-burst quiet patches are sub-second):
        // once promoted, the 2.5s clean dwell can never elapse mid-burst.
        var promoted = false
        var held = true
        for k in 0..<20 {
            t = driveClean(&dp, from: t, frames: k.isMultiple(of: 2) ? 20 : 38) // ~333ms / ~633ms
            dp.noteNetworkLate(t)
            if dp.depth == 2 { promoted = true }
            if promoted, dp.depth != 2 { held = false }
        }
        XCTAssertTrue(promoted)
        XCTAssertTrue(held, "no mid-burst demote while lates keep arriving")
        XCTAssertEqual(dp.depth, 2)
    }

    // MARK: Demote dwell + min-hold

    func testDemoteAfterCleanDwellRespectsMinHold() {
        // Tolerance 0 = the STRICT dwell arm: the demote waits a fully clean 2.5s after the LAST
        // network late, which dominates the 1s hold.
        var strict = PacerDepthPolicy.Config()
        strict.demoteToleranceLates = 0
        var dp = PacerDepthPolicy(config: strict, adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 130) // past the promote warmup
        dp.noteNetworkLate(t)
        t = driveClean(&dp, from: t, frames: 30)
        dp.noteNetworkLate(t)
        XCTAssertEqual(dp.depth, 2)
        let lastLate = t
        var demotedAt: Double?
        for _ in 0..<300 { // 5s clean
            t += 1.0 / 60.0
            dp.noteArrival(t)
            dp.notePresent(t)
            if dp.depth == 1, demotedAt == nil { demotedAt = t }
        }
        guard let demotedAt else { XCTFail("never demoted on a clean link")
            return
        }
        XCTAssertGreaterThanOrEqual(demotedAt - lastLate, 2.5)
        XCTAssertLessThanOrEqual(
            demotedAt - lastLate,
            2.5 + 2.0 / 60.0,
            "demote fires on the first evaluation past the dwell",
        )

        // MIN-HOLD arm: a config whose dwell (0.5s) is SHORTER than the hold (1.5s) — the demote
        // must wait for the hold even though the dwell elapsed.
        var cfg = PacerDepthPolicy.Config()
        cfg.demoteCleanSeconds = 0.5
        cfg.minHoldSeconds = 1.5
        cfg.demoteToleranceLates = 0
        var dph = PacerDepthPolicy(config: cfg, adaptEnabled: true)
        var th = driveClean(&dph, from: 0, frames: 130)
        dph.noteNetworkLate(th)
        th = driveClean(&dph, from: th, frames: 30)
        dph.noteNetworkLate(th)
        XCTAssertEqual(dph.depth, 2)
        let promotedAt = th
        var demotedAtH: Double?
        for _ in 0..<240 {
            th += 1.0 / 60.0
            dph.noteArrival(th)
            dph.notePresent(th)
            if dph.depth == 1, demotedAtH == nil { demotedAtH = th }
        }
        guard let demotedAtH else { XCTFail("min-hold arm never demoted")
            return
        }
        XCTAssertGreaterThanOrEqual(demotedAtH - promotedAt, 1.5, "min-hold must dominate a shorter dwell")
        XCTAssertLessThanOrEqual(demotedAtH - promotedAt, 1.5 + 2.0 / 60.0)
    }

    /// Drives promote-then-one-mid-dwell-late and returns when the depth came back to 1.
    private func demoteTimeWithOneMidDwellLate(tolerance: Int) -> (demotedAt: Double?, lateAt: Double) {
        var cfg = PacerDepthPolicy.Config()
        cfg.demoteToleranceLates = tolerance
        var dp = PacerDepthPolicy(config: cfg, adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 150) // 2.5s — past the warmup
        dp.noteNetworkLate(t)
        t = driveClean(&dp, from: t, frames: 20)
        dp.noteNetworkLate(t)
        XCTAssertEqual(dp.depth, 2, "burst promotes")
        // ~1.2s of clean flow, then ONE genuine network late mid-dwell.
        t = driveClean(&dp, from: t, frames: 72)
        dp.noteNetworkLate(t)
        let lateAt = t
        var demotedAt: Double?
        for _ in 0..<360 { // 6s clean
            t += 1.0 / 60.0
            dp.noteArrival(t)
            dp.notePresent(t)
            if dp.depth == 1, demotedAt == nil { demotedAt = t }
        }
        return (demotedAt, lateAt)
    }

    /// Default tolerance (1): a LONE network late during the dwell does NOT re-arm the full 2.5s —
    /// the demote fires once the PROMOTE-window lates age out, strictly earlier than a strict
    /// dwell anchored at the lone late. Tolerance 0 keeps the strict anchoring.
    func testDemoteToleratesOneLateInWindow() {
        let tolerant = demoteTimeWithOneMidDwellLate(tolerance: 1)
        guard let demoted = tolerant.demotedAt else { XCTFail("tolerance 1 never demoted")
            return
        }
        XCTAssertLessThan(
            demoted - tolerant.lateAt,
            2.5,
            "the lone late must not re-arm the full dwell at tolerance 1",
        )

        let strict = demoteTimeWithOneMidDwellLate(tolerance: 0)
        guard let strictDemoted = strict.demotedAt else { XCTFail("tolerance 0 never demoted")
            return
        }
        XCTAssertGreaterThanOrEqual(
            strictDemoted - strict.lateAt,
            2.5,
            "tolerance 0 = the old strict clean dwell after the last late",
        )
    }

    // MARK: Promote warmup (cold-start guard)

    /// Network lates INSIDE the warmup never promote (the action is gated, the counters are not);
    /// the identical pattern after the warmup promotes.
    func testWarmupSuppressesEarlyPromote() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 60) // 1s — inside the 2s warmup
        dp.noteNetworkLate(t)
        dp.noteNetworkLate(t + 0.3)
        XCTAssertEqual(dp.depth, 1, "no promotion inside the warmup")
        XCTAssertEqual(dp.drainCounters().lateFrames, 2, "telemetry is unconditional")
        // Same pattern once warmed: promotes.
        t = driveClean(&dp, from: t, frames: 90) // now past 2s from stream start
        dp.noteNetworkLate(t)
        dp.noteNetworkLate(t + 0.3)
        XCTAssertEqual(dp.depth, 2, "post-warmup the same pattern promotes")
    }

    /// Warmup 0 (env `AISLOPDESK_DEPTH_WARMUP_MS=0`) restores the immediate-promote behaviour.
    func testWarmupZeroPromotesImmediately() {
        var cfg = PacerDepthPolicy.Config()
        cfg.promoteWarmupSeconds = 0
        var dp = PacerDepthPolicy(config: cfg, adaptEnabled: true)
        let t = driveClean(&dp, from: 0, frames: 60)
        dp.noteNetworkLate(t)
        dp.noteNetworkLate(t + 0.3)
        XCTAssertEqual(dp.depth, 2, "warmup 0 ⇒ the old immediate promote")
    }

    // MARK: Classifier false-positive immunity (telemetry quality)

    func testIdleGapsClassifyIdleNotLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 60)
        for _ in 0..<10 { // ≥250ms gaps = host idle-skip
            t += 0.300
            dp.noteArrival(t)
            XCTAssertEqual(dp.notePresent(t), .idle)
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    func testTypingSparseNeverLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = 0.0
        for i in 0..<40 { // 150-220ms keystroke cadence
            t += 0.150 + Double(i % 8) * 0.010
            dp.noteArrival(t)
            XCTAssertNotEqual(dp.notePresent(t), .late, "sparse flow fails the dense gate")
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    /// THE MEASURED FALSE-LATE SHAPE (2026-06-11): dense 60fps flow with routine jitter gaps a
    /// hair past the old bare boundary. With the 25% slack these wobbles classify ZERO lates.
    func testDenseFlowJitterWithinSlackNeverLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 150)
        for i in 0..<600 { // ~10s, one 30ms wobble per second
            t += i.isMultiple(of: 60) ? 0.030 : 1.0 / 60.0
            dp.noteArrival(t)
            XCTAssertNotEqual(dp.notePresent(t), .late, "routine jitter within the slack must not be late")
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    /// 60→30fps downshift, no loss: the crossover emits AT MOST ONE transient late classification
    /// and NEVER promotes. The hint arm (`testIntervalHintOverridesEstimator`) is the zero-late path.
    func testFpsDownshiftNoFalseLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 120)
        var lates = 0
        for _ in 0..<150 {
            t += 1.0 / 30.0
            dp.noteArrival(t)
            if dp.notePresent(t) == .late { lates += 1 }
            XCTAssertEqual(dp.depth, 1, "a cadence change must never promote")
        }
        XCTAssertLessThanOrEqual(lates, 1, "at most the single crossover transient")
    }

    func testIntervalHintOverridesEstimator() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 120)
        XCTAssertEqual(dp.expectedIntervalSeconds, 1.0 / 60.0, accuracy: 0.002)
        dp.setIntervalHint(1.0 / 30.0)
        XCTAssertEqual(dp.expectedIntervalSeconds, 1.0 / 30.0, accuracy: 1e-9, "hint overrides the estimator instantly")
        // Boundary = factor × interval + slackFraction × interval (fix 2a).
        XCTAssertEqual(dp.lateThresholdSeconds, (1.6 + 0.25) / 30.0, accuracy: 1e-9)
        // The downshift now emits ZERO lates — not even the crossover transient.
        for _ in 0..<150 {
            t += 1.0 / 30.0
            dp.noteArrival(t)
            XCTAssertNotEqual(dp.notePresent(t), .late)
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        // Clearing the hint returns to the estimator (now converged to ~33ms).
        dp.setIntervalHint(nil)
        XCTAssertEqual(dp.expectedIntervalSeconds, 1.0 / 30.0, accuracy: 0.004)
    }

    // MARK: Re-show gap episodes

    func testReshowEpisodeCountsOnceAndResolves() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        let t = driveClean(&dp, from: 0, frames: 60)
        // Re-show ticks walk the open gap past the 28ms boundary: ONE episode however many ticks.
        dp.noteReshow(t + 0.025) // under the boundary: nothing
        XCTAssertEqual(dp.drainCounters().presentGaps, 0)
        dp.noteReshow(t + 0.033) // crosses: episode opens
        dp.noteReshow(t + 0.042) // latched: no recount
        dp.noteReshow(t + 0.050)
        // The resolving present ends the gap: classifies late (diagnostics), episode closed.
        dp.noteArrival(t + 0.058)
        XCTAssertEqual(dp.notePresent(t + 0.058), .late)
        let win = dp.drainCounters()
        XCTAssertEqual(win.presentGaps, 1, "an episode is counted exactly once")
        XCTAssertEqual(win.lateFrames, 0, "v3: the resolving present no longer counts late")
        // A NEW gap after the close can open a fresh episode.
        dp.noteReshow(t + 0.058 + 0.040)
        XCTAssertEqual(dp.drainCounters().presentGaps, 1)
    }

    func testMotionStopCountsGapEpisodeButNoLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        let t = driveClean(&dp, from: 0, frames: 60)
        // Motion stops: re-shows walk out past the boundary (episode), but NO frame ever resolves
        // the gap — the next present is past the idle cap and classifies idle, never late.
        var tick = t + 1.0 / 120.0
        while tick < t + 0.400 { dp.noteReshow(tick)
            tick += 1.0 / 120.0
        }
        dp.noteArrival(t + 0.400)
        XCTAssertEqual(dp.notePresent(t + 0.400), .idle)
        let win = dp.drainCounters()
        XCTAssertEqual(win.presentGaps, 1, "the stop boundary is one gap episode (superset semantics)")
        XCTAssertEqual(win.lateFrames, 0, "a stop boundary can never count late (nor promote)")
        XCTAssertEqual(dp.depth, 1)
    }

    // MARK: Counters + gating

    func testDrainCountersResets() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        let t = driveClean(&dp, from: 0, frames: 60)
        dp.noteNetworkLate(t)
        let first = dp.drainCounters()
        XCTAssertEqual(first.lateFrames, 1)
        let second = dp.drainCounters()
        XCTAssertEqual(second.lateFrames, 0, "drain resets the window")
        XCTAssertEqual(second.presentGaps, 0)
    }

    func testAdaptDisabledCountsButNeverPromotes() {
        var dp = PacerDepthPolicy(adaptEnabled: false)
        let t = driveClean(&dp, from: 0, frames: 130) // past the warmup
        dp.noteNetworkLate(t)
        dp.noteNetworkLate(t + 0.3)
        XCTAssertEqual(dp.depth, 1, "telemetry-only mode never moves the depth")
        XCTAssertEqual(dp.drainCounters().lateFrames, 2, "counters still flow")
    }

    // MARK: Env config

    func testConfigFromEnvironmentClampsAndDefaults() {
        let defaults = PacerDepthPolicy.Config.fromEnvironment([:])
        XCTAssertEqual(defaults, PacerDepthPolicy.Config())

        let custom = PacerDepthPolicy.Config.fromEnvironment([
            "AISLOPDESK_DEPTH_PROMOTE_LATES": "3",
            "AISLOPDESK_DEPTH_PROMOTE_WINDOW_MS": "500",
            "AISLOPDESK_DEPTH_DEMOTE_MS": "4000",
            "AISLOPDESK_DEPTH_MINHOLD_MS": "2000",
            "AISLOPDESK_DEPTH_LATE_FACTOR": "2.0",
            "AISLOPDESK_DEPTH_IDLE_MS": "350",
            "AISLOPDESK_DEPTH_LATE_SLACK_PCT": "50",
            "AISLOPDESK_DEPTH_DEMOTE_TOLERANCE": "2",
            "AISLOPDESK_DEPTH_WARMUP_MS": "5000",
        ])
        XCTAssertEqual(custom.promoteLateCount, 3)
        XCTAssertEqual(custom.promoteWindowSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(custom.demoteCleanSeconds, 4.0, accuracy: 1e-9)
        XCTAssertEqual(custom.minHoldSeconds, 2.0, accuracy: 1e-9)
        XCTAssertEqual(custom.lateGapFactor, 2.0, accuracy: 1e-9)
        XCTAssertEqual(custom.idleGapSeconds, 0.35, accuracy: 1e-9)
        XCTAssertEqual(custom.lateSlackFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(custom.demoteToleranceLates, 2)
        XCTAssertEqual(custom.promoteWarmupSeconds, 5.0, accuracy: 1e-9)

        let clamped = PacerDepthPolicy.Config.fromEnvironment([
            "AISLOPDESK_DEPTH_PROMOTE_LATES": "99", // lateTimes ring holds 4
            "AISLOPDESK_DEPTH_PROMOTE_WINDOW_MS": "0",
            "AISLOPDESK_DEPTH_DEMOTE_MS": "999999",
            "AISLOPDESK_DEPTH_LATE_FACTOR": "0.1",
            "AISLOPDESK_DEPTH_IDLE_MS": "garbage",
            "AISLOPDESK_DEPTH_LATE_SLACK_PCT": "250", // clamp 0...100 → 1.0
            "AISLOPDESK_DEPTH_DEMOTE_TOLERANCE": "99", // clamp 0...3
            "AISLOPDESK_DEPTH_WARMUP_MS": "999999", // clamp ≤ 30s
        ])
        XCTAssertEqual(clamped.promoteLateCount, 4)
        XCTAssertEqual(clamped.promoteWindowSeconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(clamped.demoteCleanSeconds, 30.0, accuracy: 1e-9)
        XCTAssertEqual(clamped.lateGapFactor, 1.1, accuracy: 1e-9)
        XCTAssertEqual(clamped.idleGapSeconds, PacerDepthPolicy.Config().idleGapSeconds, "garbage keeps the default")
        XCTAssertEqual(clamped.lateSlackFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(clamped.demoteToleranceLates, 3)
        XCTAssertEqual(clamped.promoteWarmupSeconds, 30.0, accuracy: 1e-9)

        let negSlack = PacerDepthPolicy.Config.fromEnvironment(["AISLOPDESK_DEPTH_LATE_SLACK_PCT": "-10"])
        XCTAssertEqual(negSlack.lateSlackFraction, 0.0, accuracy: 1e-9, "negative slack clamps to 0 (bare boundary)")
    }
}
