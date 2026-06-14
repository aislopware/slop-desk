#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost

/// PURE AIMD congestion-control law for WF-2 adaptive bitrate. The ``VideoEncoder`` it drives is
/// HW-gated and never instantiated in a test, so this is the only headlessly-verifiable layer — it
/// covers the decision math (warmup gate, multiplicative decrease, severe-loss halving, hold-down,
/// additive recovery, [floor, ceiling] clamps, never-0, never-above-ceiling) plus the host's
/// actuation churn gate. All inputs are injected ``NetworkEstimate`` snapshots — fully deterministic.
///
/// These tests assume the production default tunables (no `AISLOPDESK_ABR_*` set in the test environment),
/// mirroring ``LiveBitratePolicyTests`` (which assumes `AISLOPDESK_BPP` unset). They reference the static
/// tunables symbolically so they stay correct even if a default is changed.
final class LiveCongestionControllerTests: XCTestCase {
    // A representative 2× HiDPI ceiling (≈45 Mbps) so the percentages are realistic.
    private let ceiling = 45_000_000

    /// Builds a `NetworkEstimate` with chosen loss / RTT congestion characteristics by folding
    /// crafted reports. Loss is EWMA-damped, so to reach a target loss we fold a steady stream.
    private func estimate(
        lossSamples: Double = 0,
        folds: Int = 0,
        rttCongested: Bool = false,
    ) -> NetworkEstimate {
        var est = NetworkEstimate()
        // Seed a clean baseline RTT (minRTT = 50) so the RTT-congestion predicate has a baseline.
        for _ in 0..<max(1, folds) {
            if rttCongested {
                // Drive smoothedRTT well above minRTT*1.25 with a rising jitter gradient.
                est.fold(
                    rttMillis: 50,
                    framesReceived: 1000,
                    unrecovered: UInt32((lossSamples * 1000).rounded()),
                    owdJitterMicros: 100,
                )
                est.fold(
                    rttMillis: 50,
                    framesReceived: 1000,
                    unrecovered: UInt32((lossSamples * 1000).rounded()),
                    owdJitterMicros: 200,
                )
                est.fold(
                    rttMillis: 500,
                    framesReceived: 1000,
                    unrecovered: UInt32((lossSamples * 1000).rounded()),
                    owdJitterMicros: 9000,
                )
            } else {
                est.fold(
                    rttMillis: 50,
                    framesReceived: 1000,
                    unrecovered: UInt32((lossSamples * 1000).rounded()),
                    owdJitterMicros: 100,
                )
            }
        }
        return est
    }

    /// Drive the controller past warmup with neutral (no-action) reports so subsequent reports act.
    /// `gradientCutEnabled` defaults to the production env default (OFF in the test environment).
    private func warmedController(
        ceiling: Int,
        floor: Int? = nil,
        gradientCutEnabled: Bool = LiveCongestionController
            .gradientCutEnabledDefault,
    ) -> LiveCongestionController {
        var ctrl = floor.map { LiveCongestionController(
            ceiling: ceiling,
            floor: $0,
            gradientCutEnabled: gradientCutEnabled,
        ) }
            ?? LiveCongestionController(ceiling: ceiling, gradientCutEnabled: gradientCutEnabled)
        let clean = estimate(lossSamples: 0, folds: 1)
        for _ in 0..<LiveCongestionController.warmupTicks { _ = ctrl.onReport(clean) }
        return ctrl
    }

    /// Component 3: an estimate whose SMOOTHED RTT is below both inflation gates (no streak, no
    /// `rttInflated`) while the MOST RECENT fold carries the gradient evidence — the trend verdict
    /// plus a raw `rawRTT` sample. With `rawRTT: 200` over the 50ms baseline the raw clears both
    /// factor+slack gates but the smoothed EWMA (≈68.75) stays under `min + slack` (≈90) — exactly
    /// the early-onset shape the gradient path exists for.
    private func gradientEstimate(rawRTT: Int?, overusing: Bool, baselineFolds: Int = 8) -> NetworkEstimate {
        var est = NetworkEstimate()
        for _ in 0..<baselineFolds {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        }
        est.fold(
            rttMillis: rawRTT,
            framesReceived: 1000,
            unrecovered: 0,
            owdJitterMicros: 100,
            owdTrendState: overusing ? 1 : 0,
            owdTrendModifiedMilli: overusing ? 80000 : 0,
        )
        return est
    }

    // MARK: Construction / clamps

    func testStartsAtCeiling() {
        let ctrl = LiveCongestionController(ceiling: ceiling)
        XCTAssertEqual(ctrl.current, ceiling, "open-loop start = pinned at the ceiling (today's behaviour)")
    }

    func testFloorDerivedFromCeilingAndNeverBelowMinimum() {
        // minFrac default 0.25 → floor = 25% of ceiling, but never below the 1 Mbps sanity minimum.
        let big = LiveCongestionController(ceiling: 40_000_000)
        XCTAssertEqual(big.floor, Int(40_000_000 * LiveCongestionController.minFrac))
        let tiny = LiveCongestionController(ceiling: 2_000_000) // 25% = 500k < 1 Mbps → clamps up.
        XCTAssertEqual(tiny.floor, LiveBitratePolicy.minimumBitrate)
        XCTAssertGreaterThan(tiny.floor, 0, "floor is NEVER 0")
    }

    func testExplicitFloorClampedIntoRange() {
        // A floor above the ceiling is clamped DOWN to the ceiling.
        let over = LiveCongestionController(ceiling: 10_000_000, floor: 99_000_000)
        XCTAssertEqual(over.floor, 10_000_000)
        // A floor below the minimum is clamped UP to the minimum (never 0).
        let under = LiveCongestionController(ceiling: 10_000_000, floor: 0)
        XCTAssertEqual(under.floor, LiveBitratePolicy.minimumBitrate)
    }

    // MARK: Warmup gating

    func testWarmupIsANoOp() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        // SUSTAINED 50% loss: 8 folds push the EWMA lossRate to ~0.33 > catastrophic 0.25, so the
        // first post-warmup report halves even at flat RTT — would normally act.
        let lossy = estimate(lossSamples: 0.5, folds: 8)
        // The first (warmupTicks - 1) reports must NOT change anything.
        for _ in 0..<(LiveCongestionController.warmupTicks - 1) {
            XCTAssertEqual(ctrl.onReport(lossy), ceiling, "no action during warmup even under heavy loss")
        }
        XCTAssertEqual(ctrl.current, ceiling)
        // The first post-warmup report acts.
        let after = ctrl.onReport(lossy)
        XCTAssertLessThan(after, ceiling, "the first post-warmup report under loss decreases")
    }

    // MARK: Multiplicative decrease

    func testDecreaseOnLossAboveThreshold() {
        var ctrl = warmedController(ceiling: ceiling)
        // Loss steady at ~5% (> 2% threshold, < 10% severe) WITH RTT inflation on the same report
        // (LOSS-TOLERANCE #4: sub-catastrophic loss needs queue corroboration) → ordinary decrease.
        let lossy = estimate(lossSamples: 0.05, folds: 8, rttCongested: true)
        let before = ctrl.current
        let after = ctrl.onReport(lossy)
        XCTAssertEqual(
            after,
            max(ctrl.floor, Int(Double(before) * LiveCongestionController.decreaseFactor)),
            "ordinary corroborated congestion → current *= decreaseFactor",
        )
        XCTAssertLessThan(after, before)
    }

    func testSevereLossHalves() {
        var ctrl = warmedController(ceiling: ceiling)
        // Sustained ~50% loss (12 folds ⇒ EWMA ~0.4 > catastrophic 0.25) → halve even at flat RTT.
        let severe = estimate(lossSamples: 0.5, folds: 12)
        let before = ctrl.current
        let after = ctrl.onReport(severe)
        XCTAssertEqual(
            after,
            max(ctrl.floor, Int(Double(before) * LiveCongestionController.severeDecreaseFactor)),
            "sustained catastrophic loss → current *= severeDecreaseFactor (halve)",
        )
        // Severe drop is steeper than an ordinary corroborated drop from the same point.
        var ordinaryCtrl = warmedController(ceiling: ceiling)
        let ordinary = ordinaryCtrl.onReport(estimate(lossSamples: 0.05, folds: 8, rttCongested: true))
        XCTAssertLessThan(after, ordinary, "severe halving drops further than an ordinary decrease")
    }

    func testDecreaseOnSustainedRTTInflation() {
        var ctrl = warmedController(ceiling: ceiling)
        // No loss, but RTT inflated past BOTH gates (minRTT×1.25 AND minRTT+slack) — must be
        // SUSTAINED for `rttStreakTicks` consecutive reports before the decrease fires.
        let rtt = estimate(lossSamples: 0, folds: 4, rttCongested: true)
        XCTAssertTrue(rtt.smoothedRTTMillis > rtt.minRTTMillis * LiveCongestionController.rttInflateFactor)
        XCTAssertTrue(rtt.smoothedRTTMillis > rtt.minRTTMillis + LiveCongestionController.rttSlackMillis)
        let before = ctrl.current
        for _ in 0..<(LiveCongestionController.rttStreakTicks - 1) {
            XCTAssertEqual(ctrl.onReport(rtt), before, "sub-streak inflation must not decrease (nor climb)")
        }
        XCTAssertLessThan(
            ctrl.onReport(rtt),
            before,
            "inflation sustained for the full streak is a congestion signal → decrease",
        )
    }

    /// REGRESSION (2026-06-10 live log): a clean low-latency LAN (minRTT ≈ 5ms, smoothedRTT wobbling
    /// 7–12ms from scheduling noise, jitter gradient flapping ~50/50, loss 0.000 on ALL reports) must
    /// NEVER decrease. The old predicate (`minRTT × 1.25` + per-report gradient flag) pinned the rate
    /// at the FLOOR for an entire session on exactly this input shape.
    func testCleanLANJitterNeverDecreases() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        est.fold(rttMillis: 5, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 10000)
        // Live-measured shape: RTT samples 5–16ms, jitter wobbling so the gradient flag flips.
        let rtts = [7, 12, 9, 15, 6, 11, 5, 16, 8, 13]
        let jitters: [UInt32] = [9000, 14000, 11000, 13500, 10000, 12500]
        for i in 0..<200 {
            est.fold(
                rttMillis: rtts[i % rtts.count],
                framesReceived: 1000,
                unrecovered: 0,
                owdJitterMicros: jitters[i % jitters.count],
            )
            XCTAssertEqual(
                ctrl.onReport(est),
                ceiling,
                "LAN scheduling wobble under the absolute slack must never leave the ceiling",
            )
        }
    }

    /// REGRESSION (EWMA cascade, re-stated for DELAY-TARGETING 2026-06-11): one sustained real
    /// inflation episode must back off ONE `cutHoldTicks` window at a time — never per-report — and
    /// every RTT decrease must be PROPORTIONAL to the queue the acting report shows
    /// (`(minRTT + slack) / smoothedRTT`, clamped). A genuinely PERSISTENT queue is now CHASED
    /// (re-decrease every ~400ms with a fresh streak) instead of bleeding latency at one small step
    /// per second — but the per-report ×every-50ms cascade stays structurally impossible.
    func testSustainedRTTInflationBacksOffOncePerRTTHoldNotPerReport() {
        var ctrl = warmedController(ceiling: ceiling)
        var est = NetworkEstimate()
        // Baseline ~5ms, then a genuine queue build-up: every report sees 80ms.
        est.fold(rttMillis: 5, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        var decreaseTicks: [Int] = []
        for i in 0..<(LiveCongestionController.holdTicks + 10) {
            est.fold(rttMillis: 80, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            let before = ctrl.current
            // Expected proportional sizing from the ACTING report's own estimate.
            let raw = (est.minRTTMillis + LiveCongestionController.rttSlackMillis) / est.smoothedRTTMillis
            let factor = min(
                LiveCongestionController.rttDecreaseCapFactor,
                max(LiveCongestionController.rttDecreaseFloorFactor, raw),
            )
            let after = ctrl.onReport(est)
            if after < before {
                decreaseTicks.append(i)
                XCTAssertEqual(
                    after,
                    max(ctrl.floor, Int(Double(before) * factor)),
                    "every RTT decrease is sized by the measured queue, clamped",
                )
            }
        }
        XCTAssertGreaterThanOrEqual(decreaseTicks.count, 2, "a persistent queue is CHASED, not waited out")
        for pair in zip(decreaseTicks, decreaseTicks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1 - pair.0,
                LiveCongestionController.cutHoldTicks,
                "RTT decreases are spaced by cutHoldTicks — no per-report cascade",
            )
        }
    }

    /// DELAY-TARGETING sizing, both ends of the clamp: a huge standing queue (smoothed ≈ 16× the
    /// drained RTT) cuts at the hard floor factor in ONE step; barely-over-threshold inflation trims
    /// at most the gentle cap — the post-congestion EWMA decay tail can never re-cut deeply.
    func testRTTDecreaseClampBounds() {
        // Hard end: minRTT ≈ 5ms, smoothedRTT driven by 300ms reports — by the time the streak gate
        // opens (3rd inflated report) the EWMA sits ≈ 100ms ⇒ raw (5+15)/100 ≈ 0.2 → clamps to 0.6.
        var ctrl = warmedController(ceiling: ceiling)
        var est = NetworkEstimate()
        est.fold(rttMillis: 5, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        var firstDecrease: (before: Int, after: Int, factor: Double)?
        for _ in 0..<10 {
            est.fold(rttMillis: 300, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            let before = ctrl.current
            let raw = (est.minRTTMillis + LiveCongestionController.rttSlackMillis) / est.smoothedRTTMillis
            let after = ctrl.onReport(est)
            if after < before { firstDecrease = (before, after, raw)
                break
            }
        }
        guard let hard = firstDecrease else { XCTFail("sustained 80ms over a 5ms baseline must decrease")
            return
        }
        XCTAssertLessThan(
            hard.factor,
            LiveCongestionController.rttDecreaseFloorFactor,
            "precondition: the raw factor is below the clamp floor",
        )
        XCTAssertEqual(
            hard.after,
            Int(Double(hard.before) * LiveCongestionController.rttDecreaseFloorFactor),
            "a huge queue cuts at the hard clamp floor in one step",
        )

        // Gentle end: LOW baseline (~10ms — the absolute 15ms slack governs, the proportional
        // fraction is sub-floor there) with smoothed crossing the min+15 gate fast enough to
        // outrun the ~1%/fold min-drift but landing within 5% of it (sample 31 — swept
        // numerically; ≤30 the drifting gate is never crossed, ≥36 the cut is deeper than the
        // cap). On HIGH baselines a barely-over scenario chases the 1.75× gate forever BY DESIGN
        // (proportional slack — see testHighBaselineWobbleDoesNotCut), so the gentle-cap contract
        // is pinned where it actually applies.
        var gentle = warmedController(ceiling: ceiling)
        var est2 = NetworkEstimate()
        est2.fold(rttMillis: 10, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        var sawGentleDecrease = false
        for _ in 0..<40 {
            est2.fold(rttMillis: 31, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            let before = gentle.current
            let raw = (est2.minRTTMillis + LiveCongestionController
                .effectiveSlackMillis(minRTTMillis: est2.minRTTMillis)) / est2.smoothedRTTMillis
            let after = gentle.onReport(est2)
            if after < before {
                sawGentleDecrease = true
                XCTAssertGreaterThan(
                    raw,
                    LiveCongestionController.rttDecreaseCapFactor,
                    "precondition: the raw factor is above the gentle cap",
                )
                XCTAssertEqual(
                    after,
                    Int(Double(before) * LiveCongestionController.rttDecreaseCapFactor),
                    "barely-over-threshold inflation trims at the gentle cap, never deeper",
                )
                break
            }
        }
        XCTAssertTrue(sawGentleDecrease, "sustained just-over-gate inflation must eventually decrease")
    }

    // MARK: Knee (ssthresh) memory

    /// A queue-corroborated decrease remembers the landed-on rate; additive recovery at/above the knee
    /// runs the cautious step, while recovery BELOW the knee keeps the full step.
    func testKneeCautiousClimbAboveFastBelow() {
        var ctrl = warmedController(ceiling: ceiling)
        // Corroborated-loss decrease (×0.85) sets the knee at the landed-on rate.
        _ = ctrl.onReport(estimate(lossSamples: 0.05, folds: 8, rttCongested: true))
        let knee = ctrl.current
        XCTAssertEqual(ctrl.kneeBps, knee, "a queue-corroborated decrease records the knee")

        // A catastrophic halve at FLAT RTT (no queue evidence) drops BELOW the knee without
        // overwriting it (rate-independent collapse is not path-capacity knowledge).
        var est = NetworkEstimate()
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        for _ in 0..<(LiveCongestionController.holdTicks + 10) {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 1000, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        XCTAssertLessThan(ctrl.current, knee)
        XCTAssertEqual(ctrl.kneeBps, knee, "a flat-RTT catastrophic halve does not move the knee")

        // Decay the loss EWMA + burn the hold-down, then watch the climb: full steps below the knee,
        // cautious steps at/above it.
        let fullStep = max(1, ceiling / LiveCongestionController.increaseDivisor)
        let cautiousStep = max(1, fullStep / LiveCongestionController.kneeCautionDivisor)
        var sawFull = false, sawCautious = false
        for _ in 0..<2000 {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            let before = ctrl.current
            let after = ctrl.onReport(est)
            guard after > before else { continue }
            if before < knee {
                XCTAssertEqual(
                    after - before,
                    fullStep,
                    "below the knee the climb uses the FULL additive step",
                )
                sawFull = true
            } else {
                XCTAssertEqual(
                    after - before,
                    cautiousStep,
                    "at/above the knee the climb uses the cautious step",
                )
                sawCautious = true
            }
            // Stop only after a couple of CAUTIOUS steps (a full step overshooting the knee must not
            // end the test before the above-knee behaviour was observed).
            if sawCautious, after >= knee + 2 * cautiousStep { break }
        }
        XCTAssertTrue(sawFull, "recovery below the knee happened at full speed")
        XCTAssertTrue(sawCautious, "climb above the knee happened at the cautious step")
    }

    /// DELAY-TARGETING trend gate: a DRAINING queue (smoothed RTT falling report-over-report, even
    /// while still over both inflation gates) must not keep cutting — the rate is already under
    /// capacity and the level is just the backlog flushing out. Only a flat/rising trend re-cuts.
    func testDrainingQueueNeverReCuts() {
        var ctrl = warmedController(ceiling: ceiling)
        var est = NetworkEstimate()
        est.fold(rttMillis: 5, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        // Build a real standing queue (rising trend) until the first cut lands.
        var afterFirstCut: Int?
        for _ in 0..<10 {
            est.fold(rttMillis: 300, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            let before = ctrl.current
            if ctrl.onReport(est) < before { afterFirstCut = ctrl.current
                break
            }
        }
        guard let cut = afterFirstCut else { XCTFail("a rising queue must cut")
            return
        }
        // The queue now DRAINS: samples fall away BELOW the smoothed level, so the smoothed EWMA
        // falls monotonically — yet stays far above both inflation gates for many reports. (Samples
        // above the still-climbing EWMA would read as a RISING trend — that catchup phase may
        // legitimately re-cut; the contract under test is the falling-trend block.)
        var rtt = 100
        for _ in 0..<40 {
            rtt = max(6, rtt - 12)
            est.fold(rttMillis: rtt, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
            XCTAssertGreaterThanOrEqual(
                ctrl.current,
                cut,
                "a draining queue (falling smoothed trend) never re-cuts, however inflated the level still is",
            )
        }
    }

    /// The knee expires after `kneeTTLTicks` without re-confirmation — a stale knee must not cap the
    /// climb forever.
    func testKneeExpiresAfterTTL() {
        var ctrl = warmedController(ceiling: ceiling)
        _ = ctrl.onReport(estimate(lossSamples: 0.05, folds: 8, rttCongested: true))
        XCTAssertNotNil(ctrl.kneeBps)
        let clean = estimate(lossSamples: 0, folds: 1)
        for _ in 0..<(LiveCongestionController.kneeTTLTicks + 1) { _ = ctrl.onReport(clean) }
        XCTAssertNil(ctrl.kneeBps, "an unconfirmed knee expires after its TTL")
    }

    // NOTE (2026-06-11): an "escalating caution" knee variant (confirmation-count doubling the
    // above-knee divisor) was built, deployed and REVERTED the same day — two live 4G sessions
    // showed cellular RTT wobble is rate-independent, so any climb slower than the base ÷8 cannot
    // cross the material-actuation gap between wobble trims and the rate pins at the floor (soft
    // image, zero latency benefit). See LiveCongestionController.kneeExpiresAtTick doc.

    // MARK: Baseline-proportional slack (2026-06-11, cellular wobble fix)

    /// CELLULAR WOBBLE (measured live on 4G, minRTT ≈ 40ms): smoothed RTT floating in the
    /// `min×1.25 < smoothed < min×1.75` band is rate-independent path texture — it must NOT cut.
    /// With the old fixed 15ms slack, 40 → 60ms tripped both gates and perpetual −5% trims pinned
    /// the rate at the floor on a path that carries 8M+.
    func testHighBaselineWobbleDoesNotCut() {
        var ctrl = warmedController(ceiling: ceiling)
        var est = NetworkEstimate()
        est.fold(rttMillis: 40, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        // Sustained 60ms on a 40ms baseline: past ×1.25 (50) and past min+15 (55), but inside
        // min + 0.75×min (70) — weather band, never a cut.
        for _ in 0..<100 {
            est.fold(rttMillis: 60, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        XCTAssertEqual(ctrl.current, ceiling, "sub-1.75×baseline wobble on a cellular path never cuts")
    }

    /// A REAL queue on the same high baseline (smoothed well past min + 0.75×min) still cuts — the
    /// proportional slack reclassifies wobble, not genuine congestion.
    func testHighBaselineRealQueueStillCuts() {
        var ctrl = warmedController(ceiling: ceiling)
        var est = NetworkEstimate()
        est.fold(rttMillis: 40, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        var cut = false
        for _ in 0..<20 {
            est.fold(rttMillis: 120, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            let before = ctrl.current
            if ctrl.onReport(est) < before { cut = true
                break
            }
        }
        XCTAssertTrue(cut, "smoothed ≥ min + 0.75×min on a 40ms baseline is a real queue → cuts")
    }

    /// LAN baselines are unchanged by the proportional slack: 0.75 × 10ms < the 15ms absolute floor,
    /// so the effective slack is still exactly 15ms.
    func testEffectiveSlackUnchangedOnLANBaseline() {
        XCTAssertEqual(LiveCongestionController.effectiveSlackMillis(minRTTMillis: 10), 15.0)
        XCTAssertEqual(LiveCongestionController.effectiveSlackMillis(minRTTMillis: 5), 15.0)
        XCTAssertEqual(LiveCongestionController.effectiveSlackMillis(minRTTMillis: 40), 30.0)
        XCTAssertEqual(LiveCongestionController.effectiveSlackMillis(minRTTMillis: .infinity), 15.0)
    }

    /// The absolute slack governs on a tiny baseline: smoothedRTT 3× the minRTT (well past the
    /// multiplicative gate) but only a few ms of ABSOLUTE inflation must never decrease.
    func testAbsoluteSlackGuardsTinyBaseline() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        est.fold(rttMillis: 3, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        for _ in 0..<200 {
            est.fold(rttMillis: 12, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        // smoothedRTT ≈ 12ms vs minRTT ≈ 3–4ms: ×1.25 cleared, but the +15ms slack is not.
        XCTAssertEqual(ctrl.current, ceiling, "sub-slack absolute inflation on a tiny baseline never decreases")
    }

    // MARK: Hold-down

    func testHoldDownSuppressesImmediateReIncrease() {
        var ctrl = warmedController(ceiling: ceiling)
        // One corroborated-loss report drops the rate and arms the hold-down.
        let dropped = ctrl.onReport(estimate(lossSamples: 0.05, folds: 8, rttCongested: true))
        XCTAssertLessThan(dropped, ceiling)
        // Clean reports DURING the hold-down window must NOT increase the rate.
        let clean = estimate(lossSamples: 0, folds: 1)
        for _ in 0..<(LiveCongestionController.holdTicks - 1) {
            XCTAssertEqual(ctrl.onReport(clean), dropped, "no increase while the hold-down is active")
        }
    }

    // MARK: Additive recovery

    func testProbeIncreaseOnCleanLinkPastHoldDown() {
        var ctrl = warmedController(ceiling: ceiling)
        let dropped = ctrl.onReport(estimate(lossSamples: 0.05, folds: 8, rttCongested: true))
        let clean = estimate(lossSamples: 0, folds: 1)
        // Burn through the hold-down window.
        for _ in 0..<LiveCongestionController.holdTicks { _ = ctrl.onReport(clean) }
        // Now clean reports probe UP additively.
        let probed = ctrl.onReport(clean)
        XCTAssertGreaterThan(probed, dropped, "past the hold-down, a clean link climbs additively")
        let step = max(1, ceiling / LiveCongestionController.increaseDivisor)
        XCTAssertLessThanOrEqual(
            probed - dropped,
            step * (LiveCongestionController.holdTicks + 1),
            "recovery is additive, not a jump back to the ceiling",
        )
    }

    func testRecoveryNeverExceedsCeiling() {
        var ctrl = warmedController(ceiling: ceiling)
        // Drop once, then feed a long clean stream — the rate climbs but clamps AT the ceiling.
        _ = ctrl.onReport(estimate(lossSamples: 0.5, folds: 12))
        let clean = estimate(lossSamples: 0, folds: 1)
        for _ in 0..<10000 { _ = ctrl.onReport(clean) }
        XCTAssertEqual(ctrl.current, ceiling, "additive recovery clamps at the ceiling, never above")
    }

    // MARK: Transient-spike resilience (WF-2 self-audit — raw-sample decrease, no EWMA cascade)

    /// Drives the controller exactly like the host: ONE persistent ``NetworkEstimate`` folded once per
    /// report (so the EWMA carries across reports), then `onReport`. Warms past warmup with clean folds.
    private func steppedClean(_ est: inout NetworkEstimate, _ ctrl: inout LiveCongestionController, count: Int) {
        for _ in 0..<count {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
    }

    /// LOSS-TOLERANCE #4 (philosophy change, 2026-06-10): a SINGLE transient loss spike at FLAT RTT
    /// is WEATHER — a burst the FEC/LTR/kfDup machinery absorbs — and must cause ZERO decreases.
    /// (Raw sample 100% but no RTT corroboration; the EWMA only moves to ~12.5%, under the
    /// catastrophic gate. The old behaviour spent one decrease per spike; on the measured path —
    /// spikes many times a minute, rate-independent — that compounded into the ABR sawtooth.)
    func testSingleTransientSpikeAtFlatRTTNeverDecreases() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        steppedClean(&est, &ctrl, count: LiveCongestionController.warmupTicks)
        XCTAssertEqual(ctrl.current, ceiling, "warmup leaves the rate at the ceiling")

        // ONE spike report: 100% loss, RTT flat at the baseline.
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 1000, owdJitterMicros: 100)
        XCTAssertEqual(ctrl.onReport(est), ceiling, "an uncorroborated spike is weather — no decrease")
        // The EWMA tail lingers above the ORDINARY threshold for many reports — none may decrease.
        XCTAssertGreaterThan(
            est.lossRate,
            LiveCongestionController.lossThreshold,
            "EWMA loss lingers above threshold after the spike (the old cascade trap)",
        )
        for _ in 0..<60 {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            XCTAssertEqual(ctrl.onReport(est), ceiling, "the decaying EWMA tail must not decrease either")
        }
    }

    /// LOSS-TOLERANCE #4: a SUSTAINED true collapse (every report ~100% loss, flat RTT) IS acted on —
    /// via the EWMA catastrophic gate — but at most ONE halving per hold-down window, so the decaying
    /// EWMA tail after the collapse ends can never march the rate to the floor.
    func testSustainedCollapseHalvesOncePerHoldDown() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        steppedClean(&est, &ctrl, count: LiveCongestionController.warmupTicks)
        // Collapse: 100%-loss reports. The EWMA crosses 0.25 after ~3 folds → first halving.
        var firstHalveTick: Int?
        for i in 0..<LiveCongestionController.holdTicks {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 1000, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
            if firstHalveTick == nil, ctrl.current < ceiling { firstHalveTick = i }
        }
        XCTAssertNotNil(firstHalveTick, "a sustained collapse is detected within the first hold-down window")
        XCTAssertEqual(
            ctrl.current,
            max(ctrl.floor, Int(Double(ceiling) * LiveCongestionController.severeDecreaseFactor)),
            "exactly ONE halving within the hold-down window — no per-report cascade",
        )
        // Collapse ends; the EWMA tail (still > 0.25 for a few reports) must not halve again before
        // the hold-down expires.
        steppedClean(&est, &ctrl, count: 3)
        XCTAssertGreaterThanOrEqual(
            ctrl.current,
            max(ctrl.floor, Int(Double(ceiling) * LiveCongestionController.severeDecreaseFactor)),
            "the post-collapse EWMA tail never pushes below the single halving",
        )
    }

    /// REGRESSION (finding 3): a no-op decrease at the floor must NOT re-arm the hold-down. After the
    /// rate is pinned at the floor by sustained loss, the instant the link clears the controller climbs —
    /// it does not sit at the floor for an extra hold-down window re-armed by no-op decreases.
    func testNoOpDecreaseAtFloorDoesNotExtendHoldDown() {
        var ctrl = warmedController(ceiling: ceiling)
        var est = NetworkEstimate()
        // Sustained severe loss pins the rate at the floor within a few reports; keep going well past.
        for _ in 0..<200 {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 1000, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        XCTAssertEqual(ctrl.current, ctrl.floor, "sustained severe loss pins the rate at the floor")
        // The hold-down must point at/behind NOW — no-op decreases at the floor did not push it ahead.
        XCTAssertLessThanOrEqual(
            ctrl.holdUntilTick,
            ctrl.ticks,
            "no-op decreases at the floor do not extend the hold-down into the future",
        )
        // Recovery starts as soon as the catastrophic EWMA decays under its gate (~11 clean reports
        // from lossRate ≈ 1.0; the catastrophic branch keeps selecting no-op floor decreases until
        // then) — NOT after an extra hold-down window (which would be 20 more).
        for _ in 0..<11 {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        XCTAssertGreaterThan(
            ctrl.onReport(est),
            ctrl.floor,
            "recovery climbs once the EWMA clears (hold-down was not extended at the floor)",
        )
    }

    // MARK: LOSS-TOLERANCE #4 — weather loss (rate-independent, flat RTT) never gives up bitrate

    /// THE 2026-06-10 measured path shape (iperf3, inter-ISP FPT↔Viettel): loss ~0.6–9% bursts with
    /// COMPLETELY FLAT RTT (jitter 0.3ms). Backing off cannot reduce it (identical loss at 5 and
    /// 30Mbps), so the controller must hold the rate and let FEC/LTR/kfDup absorb the weather.
    func testWeatherLossFlatRTTNeverDecreases() {
        var ctrl = warmedController(ceiling: ceiling)
        var est = NetworkEstimate()
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        // A 10-second weather episode: per-report raw loss wandering 3–9%, RTT pinned at baseline.
        let lossPerMille: [UInt32] = [30, 90, 42, 60, 86, 33, 77, 51]
        for i in 0..<200 {
            est.fold(
                rttMillis: 50,
                framesReceived: 1000,
                unrecovered: lossPerMille[i % lossPerMille.count],
                owdJitterMicros: 300,
            )
            XCTAssertEqual(
                ctrl.onReport(est),
                ceiling,
                "rate-independent weather loss at flat RTT must never leave the ceiling",
            )
        }
    }

    func testLossWithRTTInflationDecreasesImmediately() {
        var ctrl = warmedController(ceiling: ceiling)
        // 5% loss + RTT inflated past both gates on the SAME report = corroborated congestion —
        // fires on the FIRST such report (no rttStreakTicks wait; the streak gate is RTT-alone).
        let congested = estimate(lossSamples: 0.05, folds: 4, rttCongested: true)
        let before = ctrl.current
        XCTAssertLessThan(
            ctrl.onReport(congested),
            before,
            "loss + queue evidence = real congestion → immediate decrease",
        )
    }

    func testCatastrophicLossHalvesEvenAtFlatRTT() {
        var ctrl = warmedController(ceiling: ceiling)
        // SUSTAINED 30% loss at flat RTT: 16 folds push the EWMA past the 0.25 catastrophic gate →
        // halve without corroboration (queue-less policer / true collapse — backing off is the only
        // safe move). A short 30% burst (few folds, EWMA still low) deliberately would NOT.
        let catastrophic = estimate(lossSamples: 0.30, folds: 16)
        XCTAssertGreaterThan(catastrophic.lossRate, LiveCongestionController.catastrophicLossThreshold)
        let after = ctrl.onReport(catastrophic)
        XCTAssertEqual(
            after,
            max(ctrl.floor, Int(Double(ceiling) * LiveCongestionController.severeDecreaseFactor)),
            "sustained catastrophic loss halves even with no RTT evidence",
        )
    }

    // MARK: CUT-CASCADE FIX (2026-06-11) — one multiplicative cut per spacing window, loss included

    /// LIVE-SESSION REPLAY (2026-06-11 VD session): a weather burst spanning several consecutive
    /// lossy reports — the measured FPT↔Viettel shape: 130–500ms episodes = 2–10 reports whose raw
    /// samples read 0.33–0.5 ONLY because a ~50ms report holds ~3 frames, with smoothed RTT pushed
    /// just past the gate by WiFi airtime noise — must cost exactly ONE ×0.85 cut per `cutHoldTicks`
    /// window. The old per-report severe-halve cascaded 29M→14M→floor inside 2 ticks, 31 times in a
    /// 4-minute session, while FEC recovered every single lost frame (unrecovered=0 — the cuts
    /// bought nothing).
    func testWeatherBurstSpanningReportsCutsOncePerWindow() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        // Clean low-baseline WiFi shape (minRTT ≈ 6ms) past warmup.
        for _ in 0..<(LiveCongestionController.warmupTicks + 5) {
            est.fold(rttMillis: 6, framesReceived: 3, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        XCTAssertEqual(ctrl.current, ceiling)
        let before = ctrl.current
        // Burst: 6 consecutive reports, RTT samples 80ms (smoothed EWMA crosses the ~21ms gate on
        // the 2nd), 1 of ~2-3 frames lost per report (raw 0.33-0.5 = "severe" by raw sample).
        for i in 0..<6 {
            est.fold(rttMillis: 80, framesReceived: UInt32(2 + i % 2), unrecovered: 1, owdJitterMicros: 500)
            _ = ctrl.onReport(est)
        }
        let oneCut = max(ctrl.floor, Int(Double(before) * LiveCongestionController.decreaseFactor))
        XCTAssertEqual(
            ctrl.current,
            oneCut,
            "a multi-report burst inside one spacing window = exactly ONE ×0.85 cut — no per-report cascade, no raw-sample halve",
        )
        XCTAssertGreaterThan(ctrl.current, ctrl.floor, "the burst must NOT cascade to the floor")
    }

    /// A single corroborated report whose RAW sample reads "severe" (1 of 2 frames lost = 50%) must
    /// take the ordinary ×0.85 step, NOT the old ×0.5 fast-halve — raw severity at ~3 frames per
    /// report is quantization noise; cut depth comes from the measured queue / EWMA collapse gates.
    func testSevereRawSampleNoLongerFastHalves() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        for _ in 0..<(LiveCongestionController.warmupTicks + 5) {
            est.fold(rttMillis: 6, framesReceived: 3, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        // Two clean-but-slow reports lift smoothedRTT past the gate (corroboration present)…
        for _ in 0..<2 {
            est.fold(rttMillis: 80, framesReceived: 3, unrecovered: 0, owdJitterMicros: 500)
            _ = ctrl.onReport(est)
        }
        XCTAssertEqual(ctrl.current, ceiling, "RTT alone below the streak gate must not have cut yet")
        // …then ONE report with a 50% raw sample (EWMA still far under catastrophic).
        est.fold(rttMillis: 80, framesReceived: 2, unrecovered: 1, owdJitterMicros: 500)
        XCTAssertLessThan(est.lossRate, LiveCongestionController.catastrophicLossThreshold)
        let after = ctrl.onReport(est)
        XCTAssertEqual(
            after,
            max(ctrl.floor, Int(Double(ceiling) * LiveCongestionController.decreaseFactor)),
            "raw-severe corroborated loss takes the ordinary ×0.85 step, never the ×0.5 fast-halve",
        )
    }

    /// A genuinely PERSISTENT corroborated-loss episode (sub-catastrophic) is still chased — it cuts
    /// again — but every consecutive pair of cuts is spaced by at least `cutHoldTicks`.
    func testPersistentCorroboratedLossCutsSpacedByWindow() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        for _ in 0..<(LiveCongestionController.warmupTicks + 5) {
            est.fold(rttMillis: 6, framesReceived: 3, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        // 5% raw loss (1 of 20 frames — EWMA stays far under catastrophic) + persistent 80ms RTT.
        var cutTicks: [Int] = []
        for i in 0..<40 {
            est.fold(rttMillis: 80, framesReceived: 20, unrecovered: 1, owdJitterMicros: 500)
            let before = ctrl.current
            _ = ctrl.onReport(est)
            if ctrl.current < before { cutTicks.append(i) }
        }
        XCTAssertGreaterThanOrEqual(cutTicks.count, 2, "a persistent episode is chased, not waited out")
        for pair in zip(cutTicks, cutTicks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1 - pair.0,
                LiveCongestionController.cutHoldTicks,
                "loss cuts share the cutHoldTicks spacing — never per-report",
            )
        }
    }

    // MARK: Floor / never-0

    func testDecreaseNeverBelowFloor() {
        var ctrl = warmedController(ceiling: ceiling)
        let severe = estimate(lossSamples: 0.5, folds: 12)
        for _ in 0..<10000 { _ = ctrl.onReport(severe) }
        XCTAssertEqual(ctrl.current, ctrl.floor, "sustained severe loss floors at `floor`, never below")
        XCTAssertGreaterThanOrEqual(ctrl.current, LiveBitratePolicy.minimumBitrate)
        XCTAssertGreaterThan(ctrl.current, 0, "the rate is NEVER 0")
    }

    // MARK: Inert when no valid evidence (telemetry-off permutation)

    func testInertWhenNoLossAndNoRTT() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        // Default estimate: loss 0, minRTT == .infinity (no valid RTT sample), no rising gradient.
        let blind = NetworkEstimate()
        for _ in 0..<1000 { _ = ctrl.onReport(blind) }
        XCTAssertEqual(ctrl.current, ceiling, "no positive evidence → never decreases; pinned at ceiling")
    }

    func testNeverDecreasesOnAbsenceOfData() {
        // RTT rejected (nil) but loss folded as 0 — the loss-only telemetry permutation.
        var est = NetworkEstimate()
        for _ in 0..<20 { est.fold(rttMillis: nil, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100) }
        var ctrl = LiveCongestionController(ceiling: ceiling)
        for _ in 0..<1000 { _ = ctrl.onReport(est) }
        XCTAssertEqual(ctrl.current, ceiling, "loss==0 + no RTT → no decrease ever")
    }

    // MARK: Actuation churn gate (the host's `material` throttle, pure + testable)

    func testChurnGateSuppressesTinyChanges() {
        // A sub-5%-of-ceiling, sub-500kbps move is NOT material.
        XCTAssertFalse(LiveCongestionController.isMaterialChange(
            previous: 45_000_000,
            target: 45_100_000,
            ceiling: ceiling,
        ))
        // A move ≥ 5% of ceiling IS material.
        XCTAssertTrue(LiveCongestionController.isMaterialChange(
            previous: 45_000_000,
            target: 42_000_000,
            ceiling: ceiling,
        ))
    }

    func testChurnGateAbsoluteFloorForSmallCeiling() {
        // With a small ceiling, 5% is tiny — the absolute 500kbps floor governs instead.
        let small = 4_000_000
        // 5% of 4M = 200k < 500k floor → a 300k move is NOT material (governed by the 500k floor).
        XCTAssertFalse(LiveCongestionController.isMaterialChange(
            previous: 4_000_000,
            target: 3_700_000,
            ceiling: small,
        ))
        // A 600k move clears the 500k floor → material.
        XCTAssertTrue(LiveCongestionController.isMaterialChange(previous: 4_000_000, target: 3_400_000, ceiling: small))
    }

    func testAdditiveTicksAccumulateToAMaterialActuation() {
        // The additive step (~3% of ceiling) is sub-material per tick, but a couple of ticks against
        // the LAST ACTUATED rate cross the 5% gate — the reason the host tracks lastActuatedBitrate.
        let step = ceiling / LiveCongestionController.increaseDivisor // ~3.125%
        XCTAssertFalse(
            LiveCongestionController.isMaterialChange(previous: ceiling - step, target: ceiling, ceiling: ceiling),
            "one additive tick is below the churn gate",
        )
        XCTAssertTrue(
            LiveCongestionController.isMaterialChange(previous: ceiling - 2 * step, target: ceiling, ceiling: ceiling),
            "two accumulated additive ticks cross the churn gate",
        )
    }

    // MARK: Component 3 — delay-gradient early cut (AISLOPDESK_ABR_GRAD, instance-level A/B)

    /// The default ships OFF (HW-feel-test convention) — and these tests assume `AISLOPDESK_ABR_GRAD`
    /// is unset, like every other tunable in this file.
    func testGradientFlagDefaultsOff() {
        XCTAssertFalse(
            LiveCongestionController.gradientCutEnabledDefault,
            "AISLOPDESK_ABR_GRAD must be unset in the test environment; the default ships OFF",
        )
        XCTAssertFalse(LiveCongestionController(ceiling: ceiling).gradientCutEnabled)
        XCTAssertTrue(
            LiveCongestionController(ceiling: ceiling, gradientCutEnabled: true).gradientCutEnabled,
            "the instance-level knob overrides the env default (harness A/B)",
        )
    }

    /// THE point of the gradient path: ONE report with trend OVERUSING + a raw-RTT-corroborated
    /// level cuts ×0.85 — while the smoothed EWMA is still under its gates (streak 0) and the
    /// smoothed path would need ~3 more reports.
    func testGradientOveruseCutsAfterOneReport() {
        var ctrl = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        let est = gradientEstimate(rawRTT: 200, overusing: true)
        // Precondition: the smoothed path is NOT yet authorized on this estimate.
        let slack = LiveCongestionController.effectiveSlackMillis(minRTTMillis: est.minRTTMillis)
        XCTAssertLessThanOrEqual(
            est.smoothedRTTMillis,
            est.minRTTMillis + slack,
            "precondition: smoothed RTT below the absolute-slack gate",
        )
        let before = ctrl.current
        let after = ctrl.onReport(est)
        XCTAssertEqual(
            after,
            max(ctrl.floor, Int(Double(before) * LiveCongestionController.gradientDecreaseFactor)),
            "one overusing+corroborated report cuts ×gradientDecreaseFactor",
        )
        XCTAssertLessThan(after, before)
    }

    /// Trend evidence alone is NOT enough — the SAME report's raw RTT must clear the factor+slack
    /// gates (a flat or rejected sample = no fresh level evidence = no cut).
    func testGradientCutRequiresRawRTTCorroboration() {
        var flatRaw = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        XCTAssertEqual(
            flatRaw.onReport(gradientEstimate(rawRTT: 50, overusing: true)),
            ceiling,
            "overusing at a FLAT raw RTT never cuts (the 4G-wobble guard)",
        )
        var rejectedRaw = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        XCTAssertEqual(
            rejectedRaw.onReport(gradientEstimate(rawRTT: nil, overusing: true)),
            ceiling,
            "a rejected raw sample (lastRTTSampleMillis nil) never authorizes a cut",
        )
    }

    /// The no-cascade invariant extends to the gradient: a persisting overuse re-cuts at most once
    /// per `cutHoldTicks` window — never per report.
    func testGradientCutRespectsCutHoldSpacing() {
        var ctrl = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        var est = NetworkEstimate()
        for _ in 0..<8 { est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100) }
        est.fold(
            rttMillis: 200,
            framesReceived: 1000,
            unrecovered: 0,
            owdJitterMicros: 100,
            owdTrendState: 1,
            owdTrendModifiedMilli: 80000,
        )
        XCTAssertLessThan(ctrl.onReport(est), ceiling, "the first cut of the episode is immediate")
        var cutTicks: [Int] = []
        var last = ctrl.current
        for i in 1...(LiveCongestionController.cutHoldTicks * 2) {
            est.fold(
                rttMillis: 200,
                framesReceived: 1000,
                unrecovered: 0,
                owdJitterMicros: 100,
                owdTrendState: 1,
                owdTrendModifiedMilli: 80000,
            )
            let after = ctrl.onReport(est)
            if after < last { cutTicks.append(i) }
            last = after
        }
        XCTAssertFalse(cutTicks.isEmpty, "a persisting overuse re-cuts at the window edge")
        XCTAssertGreaterThanOrEqual(
            cutTicks[0],
            LiveCongestionController.cutHoldTicks,
            "no second cut inside the cutHold window",
        )
        for pair in zip(cutTicks, cutTicks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1 - pair.0,
                LiveCongestionController.cutHoldTicks,
                "every consecutive cut pair is spaced by the shared window",
            )
        }
    }

    /// A/B purity: with the gate OFF (the production default), a controller fed overusing reports is
    /// tick-for-tick identical to one fed the same telemetry without trend fields.
    func testGradientDisabledIsByteIdenticalToToday() {
        var withTrend = LiveCongestionController(ceiling: ceiling) // env default = OFF
        var noTrend = LiveCongestionController(ceiling: ceiling)
        var estA = NetworkEstimate()
        var estB = NetworkEstimate()
        for i in 0..<60 {
            let rtt = i.isMultiple(of: 5) ? 200 : 50
            let lost: UInt32 = i.isMultiple(of: 7) ? 30 : 0
            estA.fold(
                rttMillis: rtt,
                framesReceived: 1000,
                unrecovered: lost,
                owdJitterMicros: 100,
                owdTrendState: 1,
                owdTrendModifiedMilli: 99000,
            )
            estB.fold(rttMillis: rtt, framesReceived: 1000, unrecovered: lost, owdJitterMicros: 100)
            XCTAssertEqual(
                withTrend.onReport(estA),
                noTrend.onReport(estB),
                "tick \(i): disabled gradient must not change any decision",
            )
        }
        XCTAssertEqual(withTrend, noTrend, "full controller state identical with the gate off")
    }

    /// Never probe up INTO a detected overuse: level-clean reports (no cut authorized) that still
    /// read OVERUSING suppress the additive increase past the hold-down; the same reports without
    /// the trend verdict climb.
    func testGradientOveruseSuppressesAdditiveIncrease() {
        var ctrl = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        let cut = ctrl.onReport(gradientEstimate(rawRTT: 200, overusing: true))
        XCTAssertLessThan(cut, ceiling)
        var est = NetworkEstimate()
        for _ in 0..<8 { est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100) }
        for _ in 0..<(LiveCongestionController.holdTicks + 10) {
            est.fold(
                rttMillis: 50,
                framesReceived: 1000,
                unrecovered: 0,
                owdJitterMicros: 100,
                owdTrendState: 1,
                owdTrendModifiedMilli: 80000,
            )
            XCTAssertEqual(
                ctrl.onReport(est),
                cut,
                "overuse detected (flat raw ⇒ no cut authorized) ⇒ no climb either",
            )
        }
        // Contrast: the detector clears ⇒ the very same level-clean reports climb.
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        XCTAssertGreaterThan(ctrl.onReport(est), cut, "the suppression lifts the instant overuse clears")
    }

    /// A gradient-ONLY cut (smoothed not inflated ⇒ not queue-corroborated) sets NO knee — an onset
    /// reflex is not capacity knowledge (the falsified-design history: knee-pinning from early cuts
    /// caps the climb for kneeTTLTicks on rate-independent wobble).
    func testGradientCutSetsNoKnee() {
        var ctrl = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        _ = ctrl.onReport(gradientEstimate(rawRTT: 200, overusing: true))
        XCTAssertLessThan(ctrl.current, ceiling, "precondition: the gradient cut landed")
        XCTAssertNil(ctrl.kneeBps, "a gradient-only cut records no knee")
    }

    /// The two paths CHAIN on a real queue: gradient cut at t0 (early reflex), the smoothed EWMA
    /// crosses its gates + the streak re-accumulates during the hold, and the PROPORTIONAL cut
    /// (sized to the by-then-measured queue, knee-setting) fires exactly at the window edge.
    func testGradientThenSustainedQueueProportionalCutNextWindow() {
        var ctrl = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        var est = NetworkEstimate()
        for _ in 0..<8 { est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100) }
        est.fold(
            rttMillis: 200,
            framesReceived: 1000,
            unrecovered: 0,
            owdJitterMicros: 100,
            owdTrendState: 1,
            owdTrendModifiedMilli: 80000,
        )
        let afterGradient = ctrl.onReport(est)
        XCTAssertEqual(afterGradient, Int(Double(ceiling) * LiveCongestionController.gradientDecreaseFactor))
        XCTAssertNil(ctrl.kneeBps)
        var cutTick: Int?
        for i in 1...(LiveCongestionController.cutHoldTicks + 2) {
            est.fold(
                rttMillis: 250,
                framesReceived: 1000,
                unrecovered: 0,
                owdJitterMicros: 100,
                owdTrendState: 1,
                owdTrendModifiedMilli: 80000,
            )
            let before = ctrl.current
            if ctrl.onReport(est) < before { cutTick = i
                break
            }
        }
        XCTAssertEqual(
            cutTick,
            LiveCongestionController.cutHoldTicks,
            "the standing queue's next cut fires exactly at the shared window edge",
        )
        XCTAssertNotNil(ctrl.kneeBps, "the queue-corroborated follow-up cut sets the knee")
    }

    func testGradientDuringWarmupIsNoOp() {
        var ctrl = LiveCongestionController(ceiling: ceiling, gradientCutEnabled: true)
        let est = gradientEstimate(rawRTT: 200, overusing: true)
        for _ in 0..<(LiveCongestionController.warmupTicks - 1) {
            XCTAssertEqual(ctrl.onReport(est), ceiling, "no gradient action during warmup")
        }
        XCTAssertLessThan(ctrl.onReport(est), ceiling, "the first post-warmup overusing report cuts")
    }

    // MARK: Fix 4 (2026-06-11) — cut-reason attribution (telemetry only, zero behaviour change)

    /// THE attribution pin the host log needs: a gradient-authorized cut reports `.gradient`, an
    /// RTT-streak (proportional) cut reports `.rttStreak` — and `decide` is behaviour-identical to
    /// `onReport` (same target).
    func testCutReasonAttributesGradientVsRttStreak() {
        // Gradient arm: trend OVERUSING + raw-RTT corroboration, smoothed EWMA still under its
        // gates ⇒ ONLY the gradient branch can have authorized this cut.
        var gradient = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        var control = warmedController(ceiling: ceiling, gradientCutEnabled: true)
        let gEst = gradientEstimate(rawRTT: 200, overusing: true)
        let gDecision = gradient.decide(gEst)
        XCTAssertLessThan(gDecision.target, ceiling, "precondition: the gradient cut landed")
        XCTAssertEqual(gDecision.reason, .gradient, "a gradient-authorized cut is attributed to .gradient")
        XCTAssertEqual(
            gDecision.target,
            control.onReport(gEst),
            "decide() and onReport() are the same control law (fix 4 changes no behaviour)",
        )

        // RTT-streak arm (gradient gate OFF, no trend fields): sustained smoothed inflation for
        // rttStreakTicks consecutive reports ⇒ the proportional delay-targeting cut.
        var rttCtrl = warmedController(ceiling: ceiling, gradientCutEnabled: false)
        var est = NetworkEstimate()
        for _ in 0..<8 { est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100) }
        var lastReason = LiveCongestionController.CutReason.hold
        var cutTarget = ceiling
        for _ in 0..<(LiveCongestionController.rttStreakTicks + 2) {
            est.fold(rttMillis: 400, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            let d = rttCtrl.decide(est)
            if d.target < cutTarget { cutTarget = d.target
                lastReason = d.reason
                break
            }
        }
        XCTAssertLessThan(cutTarget, ceiling, "precondition: the RTT cut landed")
        XCTAssertEqual(lastReason, .rttStreak, "a sustained-RTT proportional cut is attributed to .rttStreak")
    }

    /// The no-action and increase reasons: warmup ticks report `.warmup`, a clean post-warmup
    /// climb reports `.probe`, and a clean report still inside the post-cut hold-down reports
    /// `.hold`.
    func testNoCutReasonsWarmupProbeHold() {
        var ctrl = LiveCongestionController(ceiling: ceiling, gradientCutEnabled: false)
        let clean = estimate(lossSamples: 0, folds: 1)
        for _ in 0..<(LiveCongestionController.warmupTicks - 1) {
            XCTAssertEqual(ctrl.decide(clean).reason, .warmup)
        }
        // Past warmup, at the ceiling: the additive branch runs (clamped no-op) ⇒ .probe.
        XCTAssertEqual(ctrl.decide(clean).reason, .probe)

        // After a catastrophic halve, a clean report inside the hold-down holds.
        var held = warmedController(ceiling: ceiling, gradientCutEnabled: false)
        let collapse = estimate(lossSamples: 0.5, folds: 8)
        let cut = held.decide(collapse)
        XCTAssertEqual(cut.reason, .catastrophic)
        XCTAssertLessThan(cut.target, ceiling)
        XCTAssertEqual(held.decide(clean).reason, .hold, "clean report inside the hold-down = .hold")
    }
}
#endif
