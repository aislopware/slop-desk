import XCTest
@testable import AislopdeskClientUI

/// PURE OUT-path coalescer tests (the terminal resize-corruption fix). Verifies that a fast
/// window-drag's burst of DISTINCT `.resize` events collapses to its LATEST while `.input(Data)`
/// is an order-preserving hard BARRIER — so the host PTY converges to the FINAL size with as few
/// `TIOCSWINSZ` as possible (one clean zsh SIGWINCH → one clean prompt redraw) without ever
/// corrupting input byte order.
///
/// This is the 1:1 analog of `InputMotionCoalescerTests`: `.resize` is the coalescible class
/// (latest-wins) and `.input` is the barrier (the role mouse buttons/keys play there). No
/// `ConnectionViewModel`, no `AislopdeskClient`, no clock, no socket — `coalesceOut` is pure, so the
/// TRAILING-EDGE GUARANTEE (the last resize of every batch always survives) is asserted with zero
/// wall-clock dependence.
final class OutEventCoalescerTests: XCTestCase {
    private func resize(_ c: UInt16) -> ConnectionViewModel.OutEvent { .resize(cols: c, rows: c) }
    private func input(_ bytes: [UInt8]) -> ConnectionViewModel.OutEvent { .input(Data(bytes)) }

    private func coalesce(_ b: [ConnectionViewModel.OutEvent]) -> [ConnectionViewModel.OutEvent] {
        ConnectionViewModel.coalesceOut(b)
    }

    /// A continuous drag (59→60→…→145 cols) collapses to ONLY the final size — the headline fix.
    func testDragBurstCollapsesToFinalSize() {
        let burst = (59...145).map { resize(UInt16($0)) }
        XCTAssertEqual(coalesce(burst), [resize(145)],
                       "a fast drag's distinct sizes must converge to the FINAL size only")
    }

    /// `.input` is a hard barrier: a resize on EACH side survives, and the input is between them
    /// in order — input byte order intact, resizes preserved across the barrier.
    func testInputIsAHardBarrier() {
        XCTAssertEqual(
            coalesce([resize(80), input([0x78]), resize(90)]),
            [resize(80), input([0x78]), resize(90)])
    }

    /// Both inputs survive IN ORDER; only the LATEST resize of the run between them survives.
    func testBothInputsPreservedOnlyLatestResizeOfRun() {
        XCTAssertEqual(
            coalesce([input([0x61]), resize(80), resize(90), input([0x62])]),
            [input([0x61]), resize(90), input([0x62])])
    }

    /// A batch ENDING in a resize run still emits the latest (the `InputMotionCoalescer` line-398
    /// trailing-flush invariant) — this IS the trailing-edge guarantee in pure form.
    func testTrailingResizeRunIsFlushed() {
        XCTAssertEqual(coalesce([input([0x61]), resize(80), resize(90), resize(100)]),
                       [input([0x61]), resize(100)],
                       "the trailing resize run must flush its latest — the final size always survives")
    }

    /// Empty / single passthrough (identity) — the `batch.count > 1` fast path.
    func testEmptyAndSinglePassthrough() {
        XCTAssertEqual(coalesce([]), [])
        XCTAssertEqual(coalesce([resize(120)]), [resize(120)], "identity for a single resize")
        XCTAssertEqual(coalesce([input([0x7A])]), [input([0x7A])], "identity for a single input")
    }

    /// Coalescing is idempotent: `coalesceOut(coalesceOut(x)) == coalesceOut(x)`.
    func testIdempotent() {
        let batches: [[ConnectionViewModel.OutEvent]] = [
            (10...30).map { resize(UInt16($0)) },
            [resize(80), input([1]), resize(90), resize(91), input([2]), resize(100)],
            [input([1]), input([2]), input([3])],
        ]
        for b in batches {
            let once = coalesce(b)
            XCTAssertEqual(coalesce(once), once, "coalesce(coalesce(x)) == coalesce(x)")
        }
    }

    /// The two load-bearing invariants over many hand-built + seeded-random batches:
    /// (a) the `.input` subsequence is byte-identical in count + order (input never dropped/reordered),
    /// and (b) the output has no two ADJACENT `.resize` (every run collapsed to one). Together these
    /// prove "collapses N resizes to the latest but never drops/reorders an input byte".
    func testInvariantsOverManyBatches() {
        var rng = SeededRNG(seed: 0xD15123)
        let alphabet: [() -> ConnectionViewModel.OutEvent] = [
            { self.resize(UInt16.random(in: 1...250, using: &rng)) },
            { self.input([UInt8.random(in: 0...255, using: &rng)]) },
        ]
        for _ in 0..<400 {
            let len = Int.random(in: 0...20, using: &rng)
            let batch = (0..<len).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]() }
            let out = coalesce(batch)
            XCTAssertEqual(inputsOnly(out), inputsOnly(batch), "input subsequence preserved exactly")
            XCTAssertFalse(hasAdjacentResize(out), "no two adjacent resizes survive (each run collapsed)")
        }
    }

    // MARK: helpers

    private func isResize(_ e: ConnectionViewModel.OutEvent) -> Bool {
        if case .resize = e { return true }; return false
    }
    private func inputsOnly(_ events: [ConnectionViewModel.OutEvent]) -> [ConnectionViewModel.OutEvent] {
        events.filter { !isResize($0) }
    }
    private func hasAdjacentResize(_ events: [ConnectionViewModel.OutEvent]) -> Bool {
        for i in 1..<max(1, events.count) where i < events.count {
            if isResize(events[i]) && isResize(events[i - 1]) { return true }
        }
        return false
    }
}

/// Deterministic RNG so the fuzz invariants reproduce exactly (SplitMix64). Mirrors the seeded RNG
/// in `InputMotionCoalescerTests`.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
