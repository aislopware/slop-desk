import XCTest
@testable import SlopDeskVideoClient
@testable import SlopDeskVideoProtocol

/// Pins the client-side swipe-peel feedback mirror: WHEN the chip shows (a decisively
/// horizontal candidate past the arm line — never an ordinary scroll's incidental Σx), what it
/// shows (quantized fill + the committed flip — the chip is the WHOLE feedback; the streamed
/// image never moves), and how every gesture CONCLUDES (commit on fire, retract on
/// reject/coast-expiry/cancel — the chip must never strand). The planner wraps the same
/// ``SwipeNavRecognizer`` the host runs, so acceptance itself is pinned in
/// `SwipeNavRecognizerTests`; these tests pin the FEEDBACK mapping on top.
final class SwipePeelPlannerTests: XCTestCase {
    private func began(
        _ planner: inout SwipePeelPlanner, dx: Double = 2, now: TimeInterval = 100,
    ) -> SwipePeelPlanner.Verdict {
        planner.ingest(dx: dx, dy: 0, scrollPhase: 1, momentumPhase: 0, continuous: true, now: now)
    }

    private func changed(
        _ planner: inout SwipePeelPlanner, dx: Double, dy: Double = 0, now: TimeInterval,
    ) -> SwipePeelPlanner.Verdict {
        planner.ingest(dx: dx, dy: dy, scrollPhase: 2, momentumPhase: 0, continuous: true, now: now)
    }

    private func ended(
        _ planner: inout SwipePeelPlanner, now: TimeInterval,
    ) -> SwipePeelPlanner.Verdict {
        planner.ingest(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0, continuous: true, now: now)
    }

    // MARK: Showing

    func testWheelNotchStreamStaysIdle() {
        var planner = SwipePeelPlanner()
        for i in 0..<10 {
            XCTAssertEqual(
                planner.ingest(
                    dx: 40, dy: 0, scrollPhase: 0, momentumPhase: 0, continuous: false,
                    now: 100 + Double(i) * 0.008,
                ),
                .idle,
            )
        }
    }

    func testVerticalScrollNeverShows() {
        var planner = SwipePeelPlanner()
        XCTAssertEqual(began(&planner), .idle)
        for i in 1...10 {
            XCTAssertEqual(planner.ingest(
                dx: 0, dy: 40, scrollPhase: 2, momentumPhase: 0, continuous: true,
                now: 100 + Double(i) * 0.008,
            ), .idle)
        }
        XCTAssertEqual(ended(&planner, now: 100.09), .idle)
    }

    func testSlightlyDiagonalScrollStaysBelowTheArmLineAndNeverFlashes() {
        // Σx creeps to 20 (< showTravel 24) while Σy runs away — incidental horizontal drift
        // on an ordinary scroll must not flash the chip even while dominance briefly holds.
        var planner = SwipePeelPlanner()
        XCTAssertEqual(began(&planner), .idle)
        XCTAssertEqual(changed(&planner, dx: 18, dy: 2, now: 100.01), .idle)
    }

    func testDominantDragShowsGrowsAndFlipsCommitted() {
        var planner = SwipePeelPlanner()
        XCTAssertEqual(began(&planner), .idle)
        // Σx = 42 → shown, uncommitted.
        guard case let .show(early) = changed(&planner, dx: 40, dy: 1, now: 100.02) else {
            XCTFail("expected .show once past the arm line")
            return
        }
        XCTAssertEqual(early.direction, .back)
        XCTAssertFalse(early.committed)
        // Σx = 102 ≥ fireTravel 80 → committed, fill capped at 1.
        guard case let .show(late) = changed(&planner, dx: 60, dy: 1, now: 100.05) else {
            XCTFail("expected .show past fireTravel")
            return
        }
        XCTAssertTrue(late.committed)
        XCTAssertEqual(late.progress, 1)
    }

    func testLeftwardDragMirrorsDirection() {
        var planner = SwipePeelPlanner()
        _ = began(&planner, dx: -2)
        guard case let .show(chip) = changed(&planner, dx: -60, dy: -1, now: 100.02) else {
            XCTFail("expected .show")
            return
        }
        XCTAssertEqual(chip.direction, .forward)
    }

    func testChipProgressIsQuantized() {
        var planner = SwipePeelPlanner()
        _ = began(&planner)
        for step in 1...12 {
            let verdict = changed(&planner, dx: 7, dy: 0, now: 100 + Double(step) * 0.008)
            guard case let .show(chip) = verdict else { continue }
            let steps = chip.progress / SwipePeelPlanner.progressQuantum
            XCTAssertEqual(
                steps, steps.rounded(), accuracy: 1e-9,
                "chip fill must land on the 1/32 grid so 120 Hz events don't re-render per event",
            )
        }
    }

    func testMidGestureReversalConcludesTheOldChipBeforeReshowing() {
        // A reversal that jumps the ±show dead zone in one event must NOT emit consecutive
        // `.show`s with flipped direction — same-identity SwiftUI content would ANIMATE the
        // chip's alignment flip as a full-pane slide. The old chip concludes (.retract), then
        // the next event re-shows on the new edge.
        var planner = SwipePeelPlanner()
        _ = began(&planner)
        guard case let .show(rightward) = changed(&planner, dx: 40, dy: 1, now: 100.02) else {
            XCTFail("expected .show")
            return
        }
        XCTAssertEqual(rightward.direction, .back)
        // Σx: +42 → −48 in one event — still decisively horizontal, opposite edge.
        XCTAssertEqual(changed(&planner, dx: -90, dy: 0, now: 100.03), .retract)
        guard case let .show(leftward) = changed(&planner, dx: -10, dy: 0, now: 100.04) else {
            XCTFail("expected .show on the new edge after the conclude")
            return
        }
        XCTAssertEqual(leftward.direction, .forward)
    }

    func testDominanceCollapseRetractsThenGoesIdle() {
        var planner = SwipePeelPlanner()
        _ = began(&planner)
        guard case .show = changed(&planner, dx: 40, dy: 1, now: 100.02) else {
            XCTFail("expected .show")
            return
        }
        // A vertical burst breaks 3× dominance → one retract, then quiet idle (no re-retract).
        XCTAssertEqual(changed(&planner, dx: 0, dy: 30, now: 100.03), .retract)
        XCTAssertEqual(changed(&planner, dx: 0, dy: 30, now: 100.04), .idle)
    }

    // MARK: Concluding

    func testFireAtLiftCommits() {
        var planner = SwipePeelPlanner()
        _ = began(&planner)
        _ = changed(&planner, dx: 100, dy: 1, now: 100.05)
        XCTAssertEqual(ended(&planner, now: 100.06), .commit(.back))
        // Post-fire the planner is home: the next event is plain idle.
        XCTAssertEqual(began(&planner, now: 100.5), .idle)
    }

    func testShortLiftRetracts() {
        var planner = SwipePeelPlanner()
        _ = began(&planner)
        guard case .show = changed(&planner, dx: 30, dy: 0, now: 100.02) else {
            XCTFail("expected .show")
            return
        }
        // Σx = 32: past arm (shown) but the recogniser ARMS at lift — the coast keeps showing;
        // its expiry (a straggler momentum event past the deadline) retracts.
        guard case .show = ended(&planner, now: 100.03) else {
            XCTFail("an armed lift keeps the chip up through the coast")
            return
        }
        XCTAssertEqual(
            planner.ingest(dx: 1, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.5),
            .retract,
        )
    }

    func testMomentumConfirmCommitsAndCoastFillNeverDropsBelowGlassFill() {
        var planner = SwipePeelPlanner()
        _ = began(&planner)
        // Σx = 62 → fill 62/80 ≈ 0.775 on glass.
        guard case let .show(glass) = changed(&planner, dx: 60, dy: 1, now: 100.02) else {
            XCTFail("expected .show")
            return
        }
        guard case let .show(armed) = ended(&planner, now: 100.03) else {
            XCTFail("armed lift keeps showing")
            return
        }
        // The coast denominator is confirmTravel 120 (62/120 ≈ 0.52) — the displayed fill must
        // FLOOR at the on-glass value instead of visibly dropping mid-gesture.
        XCTAssertGreaterThanOrEqual(armed.progress, glass.progress)
        // Momentum accumulates below the confirm line → still showing, fill never regresses…
        guard case let .show(coasting) = planner.ingest(
            dx: 30, dy: 0, scrollPhase: 0, momentumPhase: 1, continuous: true, now: 100.04,
        ) else {
            XCTFail("expected .show while coasting toward confirmation")
            return
        }
        XCTAssertGreaterThanOrEqual(coasting.progress, armed.progress)
        // …and the combined 132 ≥ 120 confirms: the mirror commits exactly like the host.
        XCTAssertEqual(
            planner.ingest(dx: 40, dy: 0, scrollPhase: 0, momentumPhase: 2, continuous: true, now: 100.05),
            .commit(.back),
        )
    }

    func testCancelRetractsOnlyWhenShowing() {
        var planner = SwipePeelPlanner()
        XCTAssertEqual(planner.cancel(), .idle)
        _ = began(&planner)
        guard case .show = changed(&planner, dx: 40, dy: 1, now: 100.02) else {
            XCTFail("expected .show")
            return
        }
        XCTAssertEqual(planner.cancel(), .retract)
        XCTAssertEqual(planner.cancel(), .idle)
    }

    func testSlowDeliberateDragCommitsPastTheGraduatedThreshold() {
        var planner = SwipePeelPlanner()
        _ = began(&planner)
        // 0.6 s in with Σx = 122: the slow surface's grace bar there is 128 — shown, NOT
        // committed…
        guard case let .show(mid) = changed(&planner, dx: 120, dy: 1, now: 100.6) else {
            XCTFail("expected .show")
            return
        }
        XCTAssertFalse(mid.committed)
        // …and past the ramp-top 160 the commitment flips it.
        guard case let .show(late) = changed(&planner, dx: 50, dy: 1, now: 100.7) else {
            XCTFail("expected .show")
            return
        }
        XCTAssertTrue(late.committed)
        XCTAssertEqual(ended(&planner, now: 100.8), .commit(.back))
    }

    func testRefractoryWindowSuppressesChipRightAfterCommit() {
        // The 250 ms post-fire refractory is a CROSS-SIDE trust invariant: the host swallows
        // any candidate this soon after a fire (UDP-reorder hardening), so the mirror must
        // stay dark too — a chip (and its haptic) here would promise a fire that can't happen.
        // The planner inherits the window by wrapping the same recognizer; this pins it at the
        // layer the client's actual behaviour is decided.
        var planner = SwipePeelPlanner()
        _ = began(&planner)
        _ = changed(&planner, dx: 100, dy: 1, now: 100.05)
        XCTAssertEqual(ended(&planner, now: 100.06), .commit(.back))
        // A began + decisive changed INSIDE the window: no chip.
        XCTAssertEqual(began(&planner, now: 100.2), .idle)
        XCTAssertEqual(changed(&planner, dx: 60, dy: 0, now: 100.25), .idle)
        // A fresh gesture past the window shows again.
        XCTAssertEqual(began(&planner, now: 100.5), .idle)
        guard case .show = changed(&planner, dx: 40, dy: 1, now: 100.52) else {
            XCTFail("expected .show once the refractory has passed")
            return
        }
    }

    func testSlowTierOffRetractsPastTheFlickWindow() {
        var planner = SwipePeelPlanner(slowSwipe: false)
        _ = began(&planner)
        guard case .show = changed(&planner, dx: 100, dy: 1, now: 100.1) else {
            XCTFail("expected .show inside the flick window")
            return
        }
        // Same candidate re-read past 0.45 s: the tier died with the switch off → retract.
        XCTAssertEqual(changed(&planner, dx: 1, dy: 0, now: 100.6), .retract)
    }

    // MARK: History gate (doc 20 §9.6)

    private func status(back: Bool, forward: Bool, known: Bool = true) -> SwipeNavStatusMessage {
        SwipeNavStatusMessage(
            eligible: true, slowTier: true, fireTravel: 80,
            canGoBack: back, canGoForward: forward, historyKnown: known,
        )
    }

    /// The user's original report: Back/Forward greyed out in the browser, yet the drag still
    /// raised, filled, committed and haptic'd a chip for a navigation that could never happen.
    /// A dead direction must suppress `.show` AND `.commit`; a live one passes untouched.
    func testHistoryGateSuppressesDeadDirectionShowAndCommit() {
        let backOnly = status(back: true, forward: false)
        let chip = SwipePeelChipState(direction: .forward, progress: 0.5, committed: false)
        XCTAssertEqual(SwipePeelPlanner.historyGated(.show(chip), status: backOnly), .retract)
        XCTAssertEqual(SwipePeelPlanner.historyGated(.commit(.forward), status: backOnly), .retract)
        let liveChip = SwipePeelChipState(direction: .back, progress: 0.5, committed: false)
        XCTAssertEqual(SwipePeelPlanner.historyGated(.show(liveChip), status: backOnly), .show(liveChip))
        XCTAssertEqual(SwipePeelPlanner.historyGated(.commit(.back), status: backOnly), .commit(.back))
    }

    /// UNKNOWN history (AX read failed/disabled) fails OPEN — pre-gate behavior, never a dark
    /// chip; `.idle`/`.retract` pass through the gate regardless of the flags.
    func testHistoryGateFailsOpenOnUnknownAndPassesConclusions() {
        let unknown = status(back: false, forward: false, known: false)
        let chip = SwipePeelChipState(direction: .forward, progress: 0.5, committed: false)
        XCTAssertEqual(SwipePeelPlanner.historyGated(.show(chip), status: unknown), .show(chip))
        XCTAssertEqual(SwipePeelPlanner.historyGated(.commit(.back), status: unknown), .commit(.back))
        let dead = status(back: false, forward: false)
        XCTAssertEqual(SwipePeelPlanner.historyGated(.idle, status: dead), .idle)
        XCTAssertEqual(SwipePeelPlanner.historyGated(.retract, status: dead), .retract)
    }
}
