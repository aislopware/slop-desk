import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// The scroll-accumulator fold behind the actor's `injectCoalesced` (extracted as
/// ``ScrollCoalescePlanner`` so this is testable). Headline defect this pins: a lost
/// gesture-`ended` datagram leaves residual summed scroll in the accumulator, and the next
/// drains often carry NO input events (e.g. a netstats recovery batch) — an EMPTY run must
/// still reach the trailing flush, or the residual strands until the next unrelated input.
final class ScrollCoalescePlannerTests: XCTestCase {
    private let n = VideoPoint(x: 0.5, y: 0.5)
    private let interval = 1.0 / 60.0

    private func makePlanner(coalesce: Bool = true) -> ScrollCoalescePlanner {
        ScrollCoalescePlanner(injectInterval: interval, coalesceScroll: coalesce)
    }

    /// A continuous finger-drag delta (`scrollPhase == changed(2)` — the coalescable phase).
    private func changed(dx: Double, dy: Double, tag: UInt32 = 7) -> InputEvent {
        .scroll(dx: dx, dy: dy, normalized: n, scrollPhase: 2, momentumPhase: 0, continuous: true, tag: tag)
    }

    /// A gesture-`ended` boundary (`scrollPhase == 4` — never accumulates).
    private func ended(tag: UInt32 = 7) -> InputEvent {
        .scroll(dx: 0, dy: 0, normalized: n, scrollPhase: 4, momentumPhase: 0, continuous: true, tag: tag)
    }

    private func mouseDown() -> InputEvent {
        .mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)
    }

    /// Accumulates a residual that the gate HOLDS: first delta at `start` flushes (gate open),
    /// second delta right after is summed + held. Returns the planner mid-gesture with pending scroll.
    private func plannerHoldingResidual(start: Double) -> ScrollCoalescePlanner {
        var planner = makePlanner()
        XCTAssertEqual(
            planner.plan(run: [changed(dx: 0, dy: 10)], now: start),
            [changed(dx: 0, dy: 10)],
            "first continuous delta posts immediately (gate open at start)",
        )
        XCTAssertEqual(
            planner.plan(run: [changed(dx: 1, dy: 4)], now: start + 0.005),
            [],
            "a delta inside the gate is HELD (the ≤1/interval cap)",
        )
        XCTAssertTrue(planner.hasPendingScroll)
        return planner
    }

    // MARK: - The defect: empty-run trailing flush

    /// THE FIX PIN: the gesture-`ended` datagram is LOST, so the residual sits in the accumulator.
    /// The next drain carries no input (a netstats/keepalive recovery batch ⇒ `plan(run: [])`).
    /// Once the gate has elapsed, that empty run MUST flush the residual — pre-fix the empty-run
    /// early-return sat ABOVE the trailing flush, stranding it until the next unrelated input.
    func testEmptyRunFlushesHeldResidualAfterGate() {
        var planner = plannerHoldingResidual(start: 100.0)
        let out = planner.plan(run: [], now: 100.0 + 2 * interval)
        XCTAssertEqual(
            out,
            [changed(dx: 1, dy: 4)],
            "an empty run past the gate must flush the stranded residual",
        )
        XCTAssertFalse(planner.hasPendingScroll)
    }

    /// The cap is preserved: an empty run INSIDE the gate holds the residual (no early double-post).
    func testEmptyRunInsideGateHoldsResidual() {
        var planner = plannerHoldingResidual(start: 100.0)
        XCTAssertEqual(planner.plan(run: [], now: 100.0 + 0.008), [])
        XCTAssertTrue(planner.hasPendingScroll, "inside the gate the residual is held, not dropped")
    }

    // MARK: - Ported behaviour pins (byte-identical to the pre-extraction actor fold)

    /// A gesture boundary (`ended`) flushes the residual FIRST, then passes through — in order.
    func testBoundaryScrollFlushesResidualFirst() {
        var planner = plannerHoldingResidual(start: 100.0)
        let out = planner.plan(run: [ended()], now: 100.0 + 0.006)
        XCTAssertEqual(out, [changed(dx: 1, dy: 4), ended()])
        XCTAssertFalse(planner.hasPendingScroll)
    }

    /// Any non-scroll event is a boundary too: residual first, then the event.
    func testNonScrollEventFlushesResidualFirst() {
        var planner = plannerHoldingResidual(start: 100.0)
        let out = planner.plan(run: [mouseDown()], now: 100.0 + 0.006)
        XCTAssertEqual(out, [changed(dx: 1, dy: 4), mouseDown()])
    }

    /// Held deltas SUM (total travel preserved) and the flush carries the NEWEST template
    /// (normalized/tag) — one summed post once the gate elapses.
    func testHeldDeltasSumAndFlushOncePastGate() {
        var planner = makePlanner()
        _ = planner.plan(run: [changed(dx: 0, dy: 10)], now: 100.0) // posts, arms the gate
        XCTAssertEqual(planner.plan(run: [changed(dx: 2, dy: 3)], now: 100.002), [])
        XCTAssertEqual(planner.plan(run: [changed(dx: 1, dy: 5, tag: 9)], now: 100.004), [])
        let out = planner.plan(run: [changed(dx: 0, dy: 1, tag: 9)], now: 100.0 + 2 * interval)
        XCTAssertEqual(out, [changed(dx: 3, dy: 9, tag: 9)], "deltas sum; newest tag/template wins")
    }

    /// A momentum-continue coast delta (`momentumPhase == continue(2)` — the other coalescable phase).
    private func momentum(dx: Double, dy: Double, tag: UInt32 = 7) -> InputEvent {
        .scroll(dx: dx, dy: dy, normalized: n, scrollPhase: 0, momentumPhase: 2, continuous: true, tag: tag)
    }

    /// DUAL-LOSS phase purity: the gesture's `ended` AND `momentum begin` datagrams are BOTH lost,
    /// so a held on-glass `changed` residual meets the first surviving momentum-continue with no
    /// boundary in between. They must NOT merge — the summed emit carries one phase pair, so the
    /// residual's on-glass travel would be silently re-tagged as momentum (and the recogniser's
    /// on-glass sums undercounted). The domain switch flushes like a boundary instead.
    func testPhaseDomainSwitchFlushesResidualInsteadOfMerging() {
        var planner = plannerHoldingResidual(start: 100.0) // holds changed(dx:1, dy:4)
        let out = planner.plan(run: [momentum(dx: 8, dy: 0)], now: 100.0 + 0.008)
        XCTAssertEqual(
            out,
            [changed(dx: 1, dy: 4)],
            "the changed-phase residual flushes at the domain switch; the momentum delta accumulates fresh",
        )
        XCTAssertTrue(planner.hasPendingScroll, "the momentum delta is now the held residual")
        XCTAssertEqual(
            planner.plan(run: [], now: 100.0 + 2 * interval),
            [momentum(dx: 8, dy: 0)],
            "…and it emits under its OWN phase pair, never the residual's",
        )
    }

    /// `coalesceScroll == false` (the A/B legacy path) never accumulates: scrolls pass through
    /// verbatim and an empty run emits nothing (byte-identical pre-coalesce behaviour).
    func testCoalesceOffPassesScrollsThroughAndHoldsNothing() {
        var planner = makePlanner(coalesce: false)
        XCTAssertEqual(
            planner.plan(run: [changed(dx: 0, dy: 10), changed(dx: 0, dy: 4)], now: 100.0),
            [changed(dx: 0, dy: 10), changed(dx: 0, dy: 4)],
        )
        XCTAssertFalse(planner.hasPendingScroll)
        XCTAssertEqual(planner.plan(run: [], now: 200.0), [])
    }

    /// Teardown seam: `clearPending()` drops the residual so a stale gesture tail can't leak into
    /// (and be injected at the start of) the next session.
    func testClearPendingDropsResidualWithoutEmitting() {
        var planner = plannerHoldingResidual(start: 100.0)
        planner.clearPending()
        XCTAssertFalse(planner.hasPendingScroll)
        XCTAssertEqual(planner.plan(run: [], now: 200.0), [])
    }
}
