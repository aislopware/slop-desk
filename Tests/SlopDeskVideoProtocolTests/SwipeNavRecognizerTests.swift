import XCTest
@testable import SlopDeskVideoProtocol

/// Pins the swipe-back recogniser: WHAT fires (decisively horizontal completed gestures — at
/// lift when the on-glass travel suffices, via momentum confirmation for the sharp flicks that
/// spend most of their displacement AFTER the fingers leave the glass, or via the SLOW tier for
/// deliberate any-speed swipes with doubled commitment), what must NEVER fire (vertical/diagonal
/// pans, modest slow nudges, momentum of a rejected pan, wheel notches, cancelled gestures),
/// the UDP loss tolerance (lost `began`/`ended` datagrams), and the ⌘[ / ⌘] app allowlist
/// policy.
final class SwipeNavRecognizerTests: XCTestCase {
    /// Drives a whole gesture through the recogniser: began at `t0`, `changed` deltas 8 ms apart,
    /// ended at `endedAt` (default = right after the last changed). Returns the ended verdict.
    private func run(
        deltas: [(dx: Double, dy: Double)],
        t0: TimeInterval = 100,
        endedAt: TimeInterval? = nil,
        continuous: Bool = true,
        rec: inout SwipeNavRecognizer,
    ) -> SwipeNavRecognizer.Direction? {
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: continuous, now: t0))
        var t = t0
        for d in deltas {
            t += 0.008
            XCTAssertNil(rec.ingest(
                dx: d.dx, dy: d.dy, scrollPhase: 2, momentumPhase: 0, continuous: continuous, now: t,
            ))
        }
        return rec.ingest(
            dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: continuous, now: endedAt ?? t + 0.008,
        )
    }

    private func run(
        deltas: [(dx: Double, dy: Double)],
        t0: TimeInterval = 100,
        endedAt: TimeInterval? = nil,
        continuous: Bool = true,
    ) -> SwipeNavRecognizer.Direction? {
        var rec = SwipeNavRecognizer()
        return run(deltas: deltas, t0: t0, endedAt: endedAt, continuous: continuous, rec: &rec)
    }

    // MARK: Lift decision

    func testCrispRightwardFlickFiresBack() {
        // Fingers move right (natural scrolling) → history BACK.
        XCTAssertEqual(run(deltas: Array(repeating: (dx: 30.0, dy: 1.0), count: 8)), .back)
    }

    func testCrispLeftwardFlickFiresForward() {
        XCTAssertEqual(run(deltas: Array(repeating: (dx: -30.0, dy: -1.0), count: 8)), .forward)
    }

    func testVerticalScrollNeverFires() {
        XCTAssertNil(run(deltas: Array(repeating: (dx: 0.0, dy: 40.0), count: 10)))
    }

    func testDiagonalPanNeverFires() {
        // |ΣX| = 240 clears travel, but |ΣY| = 100 breaks the 3× dominance requirement.
        XCTAssertNil(run(deltas: Array(repeating: (dx: 30.0, dy: 12.5), count: 8)))
    }

    func testSlowModestDragNeverFiresNorArms() {
        // Σdx = 122 clears the FLICK travel (80) but not the slow tier's bar at 600 ms — the
        // grace ramp asks 128 pt there (easing 80 → 160 across 450–700 ms) — a modest
        // horizontal drag past the flick duration is a content nudge, not a navigation.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(run(deltas: Array(repeating: (dx: 15.0, dy: 0.0), count: 8), t0: 100, endedAt: 100.6, rec: &rec))
        // …and the rejected slow lift never ARMS: its momentum tail must not confirm either.
        XCTAssertNil(rec.ingest(dx: 300, dy: 0, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.61))
        XCTAssertNil(rec.ingest(dx: 300, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.62))
    }

    func testTinyTravelNeverFiresOrArms() {
        var rec = SwipeNavRecognizer()
        // Σdx = 2 (began) + 20 = 22 < armTravel 24 — rejected outright at lift…
        XCTAssertNil(run(deltas: Array(repeating: (dx: 2.5, dy: 0.0), count: 8), rec: &rec))
        // …so even a huge momentum tail (e.g. the trackpad's own inertia curve) can't confirm it.
        XCTAssertNil(rec.ingest(dx: 400, dy: 0, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.1))
        XCTAssertNil(rec.ingest(dx: 400, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.11))
    }

    func testBoundaryTravelAndDominanceFire() {
        // Σdx = 2 (began) + 78 = 80 exactly = fireTravel; Σdy = 20 → dominance 4×. `>=` on travel.
        XCTAssertEqual(run(deltas: [(dx: 78.0, dy: 20.0)]), .back)
        // Σdx = 120, Σdy = 40 → dominance exactly 3×. `>=` on dominance.
        XCTAssertEqual(run(deltas: [(dx: 118.0, dy: 40.0)]), .back)
    }

    func testWheelNotchStreamNeverFires() {
        // A classic wheel carries phase 0 / momentum 0 — no began ever arrives.
        var rec = SwipeNavRecognizer()
        for i in 0..<20 {
            XCTAssertNil(rec.ingest(
                dx: 40, dy: 0, scrollPhase: 0, momentumPhase: 0, continuous: false, now: 100 + Double(i) * 0.008,
            ))
        }
    }

    func testNonContinuousGestureNeverFires() {
        XCTAssertNil(run(deltas: Array(repeating: (dx: 30.0, dy: 0.0), count: 8), continuous: false))
    }

    func testCancelledGestureNeverFires() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 200, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 8, momentumPhase: 0, continuous: true, now: 100.1))
        // The abandoned accumulation must not leak into a later ended without a fresh began.
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.2))
    }

    func testEndedWithoutCandidateNeverFires() {
        // A bare ended from idle (no began, no changed) is a stray — nothing to decide from.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 300, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100))
    }

    func testOneFirePerGesture() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 200, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        XCTAssertEqual(
            rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.1),
            .back,
        )
        // A duplicate/stray ended (raw UDP duplication/reordering on the fire-and-forget input
        // channel) must not re-fire, and neither may the gesture's own momentum tail.
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.11))
        XCTAssertNil(rec.ingest(dx: 300, dy: 0, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.12))
        XCTAssertNil(rec.ingest(dx: 300, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.13))
    }

    func testFreshBeganResetsAccumulation() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 300, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        // New gesture begins — the 300 pt from the abandoned one must be gone (12 < armTravel).
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 101))
        XCTAssertNil(rec.ingest(dx: 10, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 101.01))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 101.02))
    }

    // MARK: Momentum confirmation — the sharp-flick path

    func testSharpFlickConfirmsViaMomentum() {
        // A hard flick barely touches the glass: Σ on-glass = 2+36 = 38 (≥ arm 24, < fire 80),
        // then the OS momentum tail carries the real displacement. Combined crosses 120 → BACK.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        for i in 0..<3 {
            XCTAssertNil(rec.ingest(
                dx: 12, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.01 + Double(i) * 0.008,
            ))
        }
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.04))
        XCTAssertNil(rec.ingest(dx: 50, dy: 2, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.05))
        XCTAssertEqual(
            rec.ingest(dx: 50, dy: 2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.06),
            .back,
        )
        // One-shot: the rest of the momentum tail must not fire again.
        XCTAssertNil(rec.ingest(dx: 50, dy: 2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.07))
    }

    func testCoastWindowExpires() {
        // Armed at lift, but momentum only arrives past the 0.25 s window (e.g. the tail
        // datagrams stalled) — stale confirmation must not navigate.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 40, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.06))
        XCTAssertNil(rec.ingest(dx: 500, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.4))
        // …and the expiry reset the candidate — more momentum can't revive it.
        XCTAssertNil(rec.ingest(dx: 500, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.41))
    }

    func testMomentumEndClosesAnArmedCandidate() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 40, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.06))
        // Momentum END with combined travel still short → the candidate closes for good.
        XCTAssertNil(rec.ingest(dx: 10, dy: 0, scrollPhase: 0, momentumPhase: 3, continuous: true, now: 100.08))
        XCTAssertNil(rec.ingest(dx: 500, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.09))
    }

    func testRejectedPanMomentumNeverConfirms() {
        // A vertical-ish lift is REJECTED (dominance), so its momentum tail — however
        // horizontal the residual dx — must contribute nothing.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 30, dy: 60, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.06))
        XCTAssertNil(rec.ingest(dx: 300, dy: 20, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.08))
    }

    func testArmedCandidateSumsDoNotLeakIntoNextGesture() {
        // Arm a RIGHTWARD candidate, never confirm it, then flick LEFT: the new gesture must
        // decide from its own sums (leaked +42 would cancel the leftward arm → wrong verdict).
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 40, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.06))
        XCTAssertNil(rec.ingest(dx: -2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 101))
        XCTAssertNil(rec.ingest(dx: -30, dy: -1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 101.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 101.06))
        XCTAssertEqual(
            rec.ingest(dx: -100, dy: -2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 101.08),
            .forward,
        )
    }

    // MARK: Slow tier — deliberate any-speed swipes

    func testSlowDeliberateSwipeFires() {
        // The field-trace shape v2 wrongly rejected: dur≈600 ms, Σ=(242,-16) — decisively
        // horizontal with real commitment. Native navigates this at any speed (the peel tracks
        // the fingers); the slow tier accepts it on doubled travel + 4× dominance.
        XCTAssertEqual(
            run(deltas: Array(repeating: (dx: 30.0, dy: -2.0), count: 8), t0: 100, endedAt: 100.6),
            .back,
        )
        XCTAssertEqual(
            run(deltas: Array(repeating: (dx: -30.0, dy: 2.0), count: 8), t0: 100, endedAt: 100.6),
            .forward,
        )
    }

    func testSlowArcBelowTheInterpolatedTravelRejects() {
        // Σ=(162,54): 3.0× dominance at 600 ms sits below the surface's anchor (3.6× there),
        // where the joint interpolation asks 170 pt — a wandering 2-D content pan with
        // moderate travel must not navigate.
        XCTAssertNil(run(deltas: Array(repeating: (dx: 20.0, dy: 6.75), count: 8), t0: 100, endedAt: 100.6))
    }

    func testSlowSurfaceIsContinuousAndMonotoneAcrossTheGrace() {
        // The review-caught trap this pins against: the first cut combined a duration ramp and
        // a ratio band with `min`, whose independently-gated branches FOLD along their
        // crossing — a ~2 ms duration step jumped the requirement 120 → 180 pt. The surface
        // must be cliff-free: sample densely; along duration it may move ≤ 1 pt per ms
        // (true slope tops out ≈ 0.6 pt/ms), and along ratio it must never RISE.
        for ratioStep in 0...60 {
            let ratio = 2.0 + Double(ratioStep) * 0.05
            var previous: Double?
            for durationStep in 0...300 {
                let duration = 0.451 + Double(durationStep) * 0.001
                let required = SwipeNavRecognizer.slowRequiredTravel(
                    duration: duration, sumX: ratio * 100, sumY: 100,
                    fireTravel: 80, slowFireTravel: 160, slowRelaxedTravel: 240,
                )
                guard let required else {
                    XCTFail("ratio \(ratio) ≥ 2 must always have a requirement")
                    return
                }
                if let previous {
                    XCTAssertLessThanOrEqual(
                        abs(required - previous), 1.0,
                        "fold at ratio \(ratio), duration \(duration)",
                    )
                }
                previous = required
            }
        }
        for durationStep in 0...25 {
            let duration = 0.451 + Double(durationStep) * 0.01
            var previous = Double.infinity
            for ratioStep in 0...60 {
                let ratio = 2.0 + Double(ratioStep) * 0.05
                guard let required = SwipeNavRecognizer.slowRequiredTravel(
                    duration: duration, sumX: ratio * 100, sumY: 100,
                    fireTravel: 80, slowFireTravel: 160, slowRelaxedTravel: 240,
                ) else {
                    XCTFail("ratio \(ratio) ≥ 2 must always have a requirement")
                    return
                }
                XCTAssertLessThanOrEqual(
                    required, previous + 1e-9,
                    "more dominance must never RAISE the bar (ratio \(ratio), duration \(duration))",
                )
                previous = required
            }
        }
    }

    func testFieldSeamGraceRampFiresJustPastTheFlickWindow() {
        // The field shape the 450 ms step function ate (550 ms Σ=(−131,25), 5.2× dominance —
        // the user retried and re-fired immediately): 100 ms past the window the requirement
        // eases in from the flick bar instead of doubling — the ramp asks ~112 pt @ ≥3.4× here.
        XCTAssertEqual(run(deltas: [(dx: -133.0, dy: 25.0)], t0: 100, endedAt: 100.55), .forward)
    }

    func testFieldMidBandInterpolatedTravelFires() {
        // The field shape the dominance-band step ate (839 ms Σ=(170,45), 3.8× — retried and
        // re-fired): between 4× and 2× the required travel interpolates 160 → 240; at 3.8× it
        // is ~169 pt, not a cliff-jump to 240.
        XCTAssertEqual(run(deltas: [(dx: 168.0, dy: 45.0)], t0: 100, endedAt: 100.84), .back)
    }

    func testSeamGraceStillRejectsWeakDominance() {
        // Same seam window, weak dominance (field 503 ms Σ=(−89,37), 2.4×): the anchor's
        // dominance eases 3× → 4× alongside its travel, so a scroll-ish diagonal cannot ride
        // the grace — the surface asks ~191 pt at (2.4×, 500 ms), far past this travel.
        XCTAssertNil(run(deltas: [(dx: -91.0, dy: 37.0)], t0: 100, endedAt: 100.5))
    }

    func testFieldWobblySlowSwipeFiresOnGraduatedDominance() {
        // The field shape the whole-gesture 4× rejected: dur≈860 ms, Σ=(354,−156) — a
        // deliberate slow back-swipe whose late vertical wobble drops dominance to 2.3×.
        // Native decides the axis at onset and forgives the wobble; past the 3×-fire travel
        // line the graduated rule does too.
        XCTAssertEqual(
            run(deltas: Array(repeating: (dx: 44.0, dy: -19.5), count: 8), t0: 100, endedAt: 100.86),
            .back,
        )
    }

    func testGraduatedRelaxationStillNeedsTripleTravel() {
        // Σ=(220,−100): at 2.2× dominance and 600 ms the surface asks 226 pt (interpolating
        // toward the 240 @ 2× floor) — a modest wobbly drag must not ride the relaxation.
        XCTAssertNil(run(deltas: Array(repeating: (dx: 27.25, dy: -12.5), count: 8), t0: 100, endedAt: 100.6))
    }

    func testGraduatedRelaxationStillNeedsDoubleDominance() {
        // Σ=(300,−160): huge travel but 1.9× dominance — a diagonal 2-D exploration, not a
        // nav swipe. Below 2× nothing fires regardless of commitment.
        XCTAssertNil(run(deltas: Array(repeating: (dx: 37.25, dy: -20.0), count: 8), t0: 100, endedAt: 100.6))
    }

    func testSlowBoundaryTravelAndDominanceFire() {
        // Σdx = 2 (began) + 158 = 160 exactly = slowFireTravel; Σdy = 40 → dominance exactly
        // 4×. `>=` on both, matching the flick tier's boundary semantics. Lifted at 800 ms —
        // past the grace ramp — so the pin sits on the BAND line itself, not the ramp.
        XCTAssertEqual(run(deltas: [(dx: 158.0, dy: 40.0)], t0: 100, endedAt: 100.8), .back)
    }

    func testDragHoldReleaseFiresLikeNative() {
        // Natively you may drag the page across, HOLD, and release whenever — the commit
        // happens at lift. The slow tier therefore has NO upper duration bound.
        XCTAssertEqual(
            run(deltas: Array(repeating: (dx: 40.0, dy: 1.0), count: 8), t0: 100, endedAt: 105.0),
            .back,
        )
    }

    func testSlowSwipeLostEndedFiresOnMomentumBegin() {
        // A slow qualifying swipe whose `ended` datagram was lost: the momentum-begin lift
        // synthesis must route into the slow tier too, not just the flick path.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        for i in 0..<8 {
            XCTAssertNil(rec.ingest(
                dx: 30, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.07 + Double(i) * 0.07,
            ))
        }
        XCTAssertEqual(
            rec.ingest(dx: 10, dy: 0, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.63),
            .back,
        )
    }

    func testSlowTierDisabledRestoresDurationReject() {
        // `SLOPDESK_SWIPE_NAV_SLOW=0` — the v2 escape hatch: past the flick duration every
        // lift rejects, however committed (for horizontal-scrolling browser workloads).
        var rec = SwipeNavRecognizer(slowSwipe: false)
        XCTAssertNil(run(deltas: Array(repeating: (dx: 40.0, dy: 0.0), count: 8), t0: 100, endedAt: 100.6, rec: &rec))
    }

    func testSlowFireTravelScalesWithTheKnob() {
        // fireTravel 160 → slow tier 320 (grace-ramp bar at 600 ms: 256): Σ=242 (fires at the
        // default family) is short here…
        var rec = SwipeNavRecognizer(fireTravel: 160)
        XCTAssertNil(run(deltas: Array(repeating: (dx: 30.0, dy: 0.0), count: 8), t0: 100, endedAt: 100.6, rec: &rec))
        // …and Σ=402 clears it.
        var rec2 = SwipeNavRecognizer(fireTravel: 160)
        XCTAssertEqual(
            run(deltas: Array(repeating: (dx: 50.0, dy: 0.0), count: 8), t0: 200, endedAt: 200.6, rec: &rec2),
            .back,
        )
    }

    // MARK: UDP loss tolerance

    func testLostEndedStillFiresOnMomentum() {
        // The lift already qualified on-glass, but the `ended` datagram was lost. The first
        // momentum event proves the fingers lifted — the decision runs there instead.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        for i in 0..<8 {
            XCTAssertNil(rec.ingest(
                dx: 30, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.01 + Double(i) * 0.008,
            ))
        }
        XCTAssertEqual(
            rec.ingest(dx: 40, dy: 2, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.09),
            .back,
        )
    }

    func testLostEndedArmsAndConfirmsOnMomentum() {
        // Short on-glass travel AND a lost `ended`: the synthesising momentum event both runs
        // the lift decision (→ armed) and counts as post-lift evidence itself.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 40, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 50, dy: 2, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.05))
        XCTAssertEqual(
            rec.ingest(dx: 40, dy: 2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.06),
            .back,
        )
    }

    func testLostBeganSynthesisedFromChanged() {
        // The `began` datagram was lost — a continuous `changed` run still forms a candidate.
        var rec = SwipeNavRecognizer()
        for i in 0..<4 {
            XCTAssertNil(rec.ingest(
                dx: 30, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100 + Double(i) * 0.008,
            ))
        }
        XCTAssertEqual(
            rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.04),
            .back,
        )
    }

    func testReorderedStragglerAfterFireCannotDoubleFire() {
        var rec = SwipeNavRecognizer()
        // A qualifying flick fires at lift…
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 200, dy: 2, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        XCTAssertEqual(
            rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.08),
            .back,
        )
        // …then one of its on-glass `changed` datagrams arrives LATE (UDP reorder), followed by
        // the gesture's real momentum tail. Without the refractory window the straggler
        // synthesises a fresh candidate the tail then "confirms" into a SECOND ⌘[ (back two
        // pages). The refractory window must swallow it.
        XCTAssertNil(rec.ingest(dx: 30, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.09))
        XCTAssertNil(rec.ingest(dx: 80, dy: 2, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.1))
        XCTAssertNil(rec.ingest(dx: 80, dy: 2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.11))
        XCTAssertNil(rec.ingest(dx: 80, dy: 2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.12))
    }

    func testReflickAfterRefractoryFiresNormally() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 200, dy: 2, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        XCTAssertEqual(
            rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.08),
            .back,
        )
        // A second deliberate flick 400 ms later sits past the refractory window — fires as usual.
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100.5))
        XCTAssertNil(rec.ingest(dx: 200, dy: 2, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.55))
        XCTAssertEqual(
            rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.58),
            .back,
        )
    }

    func testSynthesisedCandidateNeverArmsMomentumConfirmation() {
        var rec = SwipeNavRecognizer()
        // A long modest content pan is REJECTED at lift (slow tier: Σ=102 < the 600 ms grace
        // bar of 128)…
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 100, dy: 5, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.3))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.6))
        // …but one straggler `changed` (reordered past the ended, no fire ⇒ no refractory) forms
        // a SYNTHESISED candidate just as the pan's big momentum tail lands. Arming here would
        // navigate away from a pan the lift decision explicitly rejected — it must stay dead.
        XCTAssertNil(rec.ingest(dx: 40, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.61))
        XCTAssertNil(rec.ingest(dx: 90, dy: 2, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.62))
        XCTAssertNil(rec.ingest(dx: 90, dy: 2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.63))
    }

    func testStragglerDuringCoastDoesNotClobberTheArm() {
        // Armed at lift (Σ=(40,1) kept), then a reordered on-glass `changed` straggler from the
        // SAME gesture lands before its momentum. Synthesising from it would wipe the armed
        // sums — the genuine momentum confirm below (40+90=130 ≥ 120) would then be lost.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 38, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.06))
        XCTAssertNil(rec.ingest(dx: 5, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.07))
        XCTAssertEqual(
            rec.ingest(dx: 90, dy: 2, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.08),
            .back,
        )
    }

    func testStaleArmReleasesForALaterGesture() {
        // Armed, momentum never arrives (all lost), and a NEW began-lost gesture starts after
        // the coast window: its `changed` stream must synthesise normally, not stay blocked.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 38, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.06))
        for i in 0..<4 {
            XCTAssertNil(rec.ingest(
                dx: 30, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 101 + Double(i) * 0.008,
            ))
        }
        XCTAssertEqual(
            rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 101.04),
            .back,
        )
    }

    func testDuplicateMomentumBeginDoesNotDoubleCount() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 38, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.06))
        XCTAssertNil(rec.ingest(dx: 70, dy: 2, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.07))
        // Raw-UDP duplicate of the SAME momentum-begin datagram (a planner boundary — arrives
        // verbatim): counting it would reach 180 ≥ 120 and navigate on a marginal candidate a
        // single copy leaves short. It must be dropped…
        XCTAssertNil(rec.ingest(dx: 70, dy: 2, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.08))
        // …while a genuine (different) continue event still confirms: Σ=(130,4).
        XCTAssertEqual(
            rec.ingest(dx: 20, dy: 1, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.09),
            .back,
        )
    }

    func testStrayMomentumContinueMidPanCannotChopIt() {
        // A reordered momentum-CONTINUE from the previous gesture's tail lands inside a live
        // long pan. Running the lift decision there would reset the candidate and re-synthesise
        // the pan's remainder into a flick-shaped segment that FIRES (review-reproduced on a
        // 700 ms pan). The stray must leave the candidate intact — the WHOLE pan (Σ=(245,146),
        // 1.7× — a genuine 2-D exploration, below even the relaxed 2×) then rejects at its
        // real ended, exactly as without the stray; only the chopped tail segment (Σ=(80,6),
        // 150 ms, 13×) would qualify as a flick.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 5, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        for i in 0..<4 {
            XCTAssertNil(rec.ingest(
                dx: 40, dy: 35, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.1 + Double(i) * 0.1,
            ))
        }
        XCTAssertNil(rec.ingest(dx: 3, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.5))
        XCTAssertNil(rec.ingest(dx: 40, dy: 3, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.55))
        XCTAssertNil(rec.ingest(dx: 40, dy: 3, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.65))
        XCTAssertNil(rec.ingest(dx: 5, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.7))
    }

    func testMomentumFromIdleNeverFires() {
        // A momentum-only stream with no candidate (e.g. events from before an injector rebuild).
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 60, dy: 0, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 60, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.01))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3, continuous: true, now: 100.02))
    }

    // MARK: Threshold knob

    func testFireTravelScalesThresholdFamily() {
        // fireTravel 160 → arm 48, confirm 240: a flick that fires at the default 80 only ARMS
        // here, and the same momentum that confirmed at 120 combined is no longer enough.
        var rec = SwipeNavRecognizer(fireTravel: 160)
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 98, dy: 2, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.03))
        XCTAssertNil(rec.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: 100.06))
        XCTAssertNil(rec.ingest(dx: 100, dy: 2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.08))
        XCTAssertEqual(
            rec.ingest(dx: 110, dy: 2, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.09),
            .back, // combined 310 ≥ 240 (110 ≠ 100 — an identical repeat would be dup-dropped)
        )
    }

    // MARK: Allowlist policy

    func testKnownBrowsersAndFinderAreNavigable() {
        for id in ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.apple.finder"] {
            XCTAssertTrue(SwipeNavPolicy.isNavigable(bundleID: id), id)
        }
    }

    func testUnknownAndNilAppsAreNotNavigable() {
        XCTAssertFalse(SwipeNavPolicy.isNavigable(bundleID: "com.microsoft.VSCode")) // ⌘[ = outdent!
        XCTAssertFalse(SwipeNavPolicy.isNavigable(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(SwipeNavPolicy.isNavigable(bundleID: nil))
    }

    func testExtraAppsParseAndExtend() {
        let extras = SwipeNavPolicy.extraApps(from: " com.example.One , com.example.Two,,")
        XCTAssertEqual(extras, ["com.example.One", "com.example.Two"])
        XCTAssertTrue(SwipeNavPolicy.isNavigable(bundleID: "com.example.One", extraApps: extras))
        XCTAssertFalse(SwipeNavPolicy.isNavigable(bundleID: "com.example.Three", extraApps: extras))
        XCTAssertEqual(SwipeNavPolicy.extraApps(from: nil), [])
    }

    func testBrowserPreReleaseChannelsAreNavigable() {
        // The list carries every browser's pre-release channels (Chrome beta/dev/canary, Brave
        // beta/nightly, Firefox nightly/dev-edition) — Edge/Opera/Vivaldi's must not be the
        // silent exceptions. Exact-match Set lookup ⇒ casing matters.
        for id in [
            "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
            "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper",
            "com.vivaldi.Vivaldi.snapshot",
        ] {
            XCTAssertTrue(SwipeNavPolicy.isNavigable(bundleID: id), id)
        }
    }

    func testFireTravelEnvParseRejectsToDefaultAndAcceptsBounds() {
        // The ONE parse both the injector's recogniser and the status push share — a typo must
        // not make every scroll navigate (too low) or dead the feature silently (too high).
        // Semantics are REJECT-to-default (80), not clamp-to-nearest-bound. The [20, 500]
        // acceptance is also the crash guard for `UInt16(fireTravel)` in the status message.
        for bad in [nil, "", "garbage", "nan", "inf", "-inf", "19.9", "0", "-5", "500.1", "1e9"] as [String?] {
            XCTAssertEqual(SwipeNavPolicy.fireTravel(fromEnv: bad), 80, String(describing: bad))
        }
        XCTAssertEqual(SwipeNavPolicy.fireTravel(fromEnv: "20"), 20)
        XCTAssertEqual(SwipeNavPolicy.fireTravel(fromEnv: "500"), 500)
        XCTAssertEqual(SwipeNavPolicy.fireTravel(fromEnv: "240"), 240)
    }

    // MARK: Live candidate (client peel feedback)

    func testLiveCandidateIsNilWhenIdle() {
        let rec = SwipeNavRecognizer()
        XCTAssertNil(rec.liveCandidate(now: 100))
    }

    func testLiveCandidateTracksFlickProgressAndCommitFlip() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 38, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        // Σx = 40 of fireTravel 80 → half way, not yet committed.
        var live = rec.liveCandidate(now: 100.05)
        XCTAssertEqual(live?.direction, .back)
        XCTAssertEqual(live?.progress, 0.5)
        XCTAssertEqual(live?.wouldFireAtLift, false)
        XCTAssertEqual(live?.coasting, false)
        // Σx = 100 ≥ 80 → committed; progress caps at 1.
        XCTAssertNil(rec.ingest(dx: 60, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.1))
        live = rec.liveCandidate(now: 100.1)
        XCTAssertEqual(live?.progress, 1)
        XCTAssertEqual(live?.wouldFireAtLift, true)
    }

    func testLiveCandidateReportsZeroProgressWithoutDominance() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        // Σ = (102, 50) → dominance 2.04× < 3× — feedback must not promise a fire.
        XCTAssertNil(rec.ingest(dx: 100, dy: 50, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.05))
        let live = rec.liveCandidate(now: 100.05)
        XCTAssertEqual(live?.progress, 0)
        XCTAssertEqual(live?.wouldFireAtLift, false)
    }

    func testLiveCandidateSwitchesToSlowTierPastFlickWindow() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 118, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.2))
        // Inside the flick window Σx = 120 ≥ 80 → committed…
        XCTAssertEqual(rec.liveCandidate(now: 100.2)?.wouldFireAtLift, true)
        // …but the SAME sums past 0.45 s re-gate on the slow surface: the 600 ms grace bar is
        // 128 → fill 120/128, uncommitted (accuracy: the ramp fraction is a float quotient).
        let slow = rec.liveCandidate(now: 100.6)
        XCTAssertEqual(slow?.progress ?? -1, 120.0 / 128.0, accuracy: 1e-9)
        XCTAssertEqual(slow?.wouldFireAtLift, false)
        // More travel across the (ramp-top) threshold commits again.
        XCTAssertNil(rec.ingest(dx: 44, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.7))
        XCTAssertEqual(rec.liveCandidate(now: 100.7)?.wouldFireAtLift, true)
    }

    func testLiveCandidateSlowTierGraduatedDominanceMirror() {
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        // Σ = (150, 50) → 3.0×: clears the flick's 3× inside the window…
        XCTAssertNil(rec.ingest(dx: 148, dy: 50, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.2))
        XCTAssertEqual(rec.liveCandidate(now: 100.2)?.wouldFireAtLift, true)
        // …and past the window sits below the 600 ms anchor (3.6×): the fill re-bases on the
        // INTERPOLATED travel it must actually reach — 170 pt at 3.0× — honest, not a retract.
        let slow = rec.liveCandidate(now: 100.6)
        XCTAssertEqual(slow?.progress ?? -1, 150.0 / 170.0, accuracy: 1e-9)
        XCTAssertEqual(slow?.wouldFireAtLift, false)
        // More travel raises the dominance (Σ=(190,50) → 3.8×, bar ≈168) → the surface commits.
        XCTAssertNil(rec.ingest(dx: 40, dy: 0, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.7))
        XCTAssertEqual(rec.liveCandidate(now: 100.7)?.wouldFireAtLift, true)
    }

    func testLiveCandidateSlowTierRelaxedCommitAndSubTwoDominanceZero() {
        // A wobbly-but-committed candidate (Σ=(245,−110) → 2.2×, ≥240) commits via the
        // relaxed rule — exactly what the lift would fire…
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 243, dy: -110, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.6))
        let relaxed = rec.liveCandidate(now: 100.6)
        XCTAssertEqual(relaxed?.progress, 1)
        XCTAssertEqual(relaxed?.wouldFireAtLift, true)
        // …while below 2× the feedback stays dark however big the travel (Σ=(300,−160) → 1.9×).
        var diagonal = SwipeNavRecognizer()
        XCTAssertNil(diagonal.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(diagonal.ingest(dx: 298, dy: -160, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.6))
        let dark = diagonal.liveCandidate(now: 100.6)
        XCTAssertEqual(dark?.progress, 0)
        XCTAssertEqual(dark?.wouldFireAtLift, false)
    }

    func testLiveCandidateRetractsWhenSlowTierDisabled() {
        var rec = SwipeNavRecognizer(slowSwipe: false)
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 198, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.2))
        XCTAssertEqual(rec.liveCandidate(now: 100.2)?.wouldFireAtLift, true)
        // Past the flick window with no slow tier a lift can only reject on duration.
        let live = rec.liveCandidate(now: 100.6)
        XCTAssertEqual(live?.progress, 0)
        XCTAssertEqual(live?.wouldFireAtLift, false)
    }

    func testLiveCandidateCoastsTowardConfirmThenExpires() {
        var rec = SwipeNavRecognizer()
        // Σx = 60: arms at lift (≥24, <80) — the live view flips to coasting.
        XCTAssertNil(run(deltas: [(dx: 58.0, dy: 1.0)], rec: &rec))
        var live = rec.liveCandidate(now: 100.05)
        XCTAssertEqual(live?.coasting, true)
        XCTAssertEqual(live?.wouldFireAtLift, false)
        XCTAssertEqual(live?.progress, 0.5) // 60 of confirmTravel 120
        // Momentum accumulates toward confirmation and progress follows.
        XCTAssertNil(rec.ingest(dx: 30, dy: 0, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.06))
        live = rec.liveCandidate(now: 100.06)
        XCTAssertEqual(live?.progress, 0.75) // 90 of 120
        // Past the coast deadline the live view vanishes (the arm is stale).
        XCTAssertNil(rec.liveCandidate(now: 100.5))
    }

    func testLiveCandidateIsNilAfterFireAndDuringRefractoryBegan() {
        var rec = SwipeNavRecognizer()
        XCTAssertEqual(run(deltas: Array(repeating: (dx: 30.0, dy: 1.0), count: 8), rec: &rec), .back)
        XCTAssertNil(rec.liveCandidate(now: 100.08)) // decided → reset
        // A began inside the 250 ms refractory window is suppressed — no live candidate either.
        XCTAssertNil(rec.ingest(dx: 30, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100.2))
        XCTAssertNil(rec.liveCandidate(now: 100.2))
    }
}
