import XCTest
@testable import SlopDeskVideoHost

/// Pins the swipe-back flick recogniser: WHAT fires (decisively horizontal completed gestures —
/// at lift when the on-glass travel suffices, or via momentum confirmation for the sharp flicks
/// that spend most of their displacement AFTER the fingers leave the glass), what must NEVER
/// fire (vertical/diagonal pans, slow drags, momentum of a rejected pan, wheel notches,
/// cancelled gestures), the UDP loss tolerance (lost `began`/`ended` datagrams), and the
/// ⌘[ / ⌘] app allowlist policy.
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

    func testSlowHorizontalDragNeverFires() {
        // Plenty of travel, decisively horizontal — but 0.6 s from began to ended is a content
        // pan (spreadsheet / wide code), not a navigation flick.
        XCTAssertNil(run(deltas: Array(repeating: (dx: 30.0, dy: 0.0), count: 8), t0: 100, endedAt: 100.6))
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
        // A long horizontal content pan is REJECTED at lift (duration)…
        XCTAssertNil(rec.ingest(dx: 2, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        XCTAssertNil(rec.ingest(dx: 300, dy: 5, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.3))
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
        // 700 ms pan). The stray must leave the candidate intact — the pan then rejects on
        // duration at its real ended, exactly as without the stray.
        var rec = SwipeNavRecognizer()
        XCTAssertNil(rec.ingest(dx: 5, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: 100))
        for i in 0..<4 {
            XCTAssertNil(rec.ingest(
                dx: 40, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.1 + Double(i) * 0.1,
            ))
        }
        XCTAssertNil(rec.ingest(dx: 3, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.5))
        XCTAssertNil(rec.ingest(dx: 40, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.55))
        XCTAssertNil(rec.ingest(dx: 40, dy: 1, scrollPhase: 2, momentumPhase: 0, continuous: true, now: 100.65))
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
}
