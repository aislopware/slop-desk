import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// PURE motion-coalescer tests (the input-latency fix). Verifies that consecutive
/// same-class pointer-motion runs collapse to their latest WITHOUT reordering across any
/// button/key/scroll/text barrier — the correctness the ordered inbound consumer won must
/// not regress. No `InputInjector`, no CGEvents, no socket.
final class InputMotionCoalescerTests: XCTestCase {
    // Distinct positions so we can assert WHICH motion survived (latest-wins). x == y == id.
    private func move(_ id: Double) -> InputEvent { .mouseMove(normalized: VideoPoint(x: id, y: id), tag: 0) }
    private func drag(_ id: Double, _ b: MouseButton = .left) -> InputEvent {
        .mouseDrag(button: b, normalized: VideoPoint(x: id, y: id), clickCount: 1, modifiers: [], tag: 0)
    }

    private func down(_ b: MouseButton = .left) -> InputEvent {
        .mouseDown(button: b, normalized: VideoPoint(x: 0, y: 0), clickCount: 1, modifiers: [], tag: 0)
    }

    private func up(_ b: MouseButton = .left) -> InputEvent {
        .mouseUp(button: b, normalized: VideoPoint(x: 0, y: 0), clickCount: 1, modifiers: [], tag: 0)
    }

    private func scroll(_ dy: Double)
        -> InputEvent { .scroll(dx: 0, dy: dy, normalized: VideoPoint(x: 0, y: 0), tag: 0) }
    private func key(_ kc: UInt16) -> InputEvent { .key(keyCode: kc, down: true, modifiers: [], tag: 0) }
    private func text(_ s: String) -> InputEvent { .text(s, tag: 0) }

    private func coalesce(_ b: [InputEvent]) -> [InputEvent] { InputMotionCoalescer.coalesce(b) }

    func testCollapsesConsecutiveMovesToLatest() {
        XCTAssertEqual(coalesce([move(0.1), move(0.2), move(0.3)]), [move(0.3)])
    }

    func testCollapsesConsecutiveDragsToLatest() {
        XCTAssertEqual(coalesce([drag(0.1), drag(0.2), drag(0.3)]), [drag(0.3)])
    }

    /// A move that physically preceded a click must flush BEFORE the down, and the post-down
    /// move is a separate run; down/up order intact.
    func testNeverReordersAcrossMouseDown() {
        XCTAssertEqual(
            coalesce([move(0.1), move(0.2), down(), move(0.3), up()]),
            [move(0.2), down(), move(0.3), up()],
        )
    }

    /// Drags collapse to latest but stay strictly between down and up (clickState framing).
    func testDownDragUpFramingPreserved() {
        XCTAssertEqual(
            coalesce([down(), drag(0.1), drag(0.2), drag(0.3), up()]),
            [down(), drag(0.3), up()],
        )
    }

    /// A hover-run and a drag-run never merge; a class change is a flush boundary.
    func testMoveAndDragAreSeparateBuckets() {
        let batch = [move(0.1), drag(0.2), move(0.3)]
        XCTAssertEqual(coalesce(batch), batch, "class changes are flush boundaries — nothing collapses")
    }

    /// Interleaved drags of DIFFERENT buttons are the same `.mouseDrag` class, so they DO
    /// collapse — but the surviving event keeps the latest button (matches absolute latest-wins;
    /// real streams never interleave two held buttons mid-run).
    func testTrailingMotionRunFlushed() {
        XCTAssertEqual(
            coalesce([down(), move(0.1), move(0.2)]),
            [down(), move(0.2)],
            "a batch ending in a motion run still emits the latest position",
        )
    }

    func testKeyScrollTextNeverDropped() {
        let batch = [move(0.1), key(10), move(0.2), scroll(3), text("a"), move(0.3), move(0.4)]
        XCTAssertEqual(coalesce(batch), [move(0.1), key(10), move(0.2), scroll(3), text("a"), move(0.4)])
    }

    func testEmptyAndSingleEvent() {
        XCTAssertEqual(coalesce([]), [])
        XCTAssertEqual(coalesce([down()]), [down()], "identity for a single non-motion event")
        XCTAssertEqual(coalesce([move(0.5)]), [move(0.5)], "identity for a single motion event")
    }

    func testIdempotentOnAlreadyCoalesced() {
        let batches: [[InputEvent]] = [
            [move(0.1), move(0.2), down(), move(0.3), up()],
            [down(), drag(0.1), drag(0.2), up(), move(0.9)],
            [key(1), scroll(2), text("z")],
        ]
        for b in batches {
            let once = coalesce(b)
            XCTAssertEqual(coalesce(once), once, "coalesce(coalesce(x)) == coalesce(x)")
        }
    }

    /// The two load-bearing invariants over many batches (hand-built + seeded-random):
    /// (a) the subsequence of NON-motion events is byte-identical in count + order, and
    /// (b) the output has no two ADJACENT same-class motion events. Together these prove
    /// "collapses N motion to 1 latest but never drops/reorders a button/key/scroll/text".
    func testInvariantsOverManyBatches() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        let alphabet: [() -> InputEvent] = [
            { self.move(Double.random(in: 0...1, using: &rng)) },
            { self.drag(Double.random(in: 0...1, using: &rng)) },
            { self.down() }, { self.up() }, { self.scroll(1) }, { self.key(7) }, { self.text("x") },
        ]
        for _ in 0..<400 {
            let len = Int.random(in: 0...20, using: &rng)
            let batch = (0..<len).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]() }
            let out = coalesce(batch)
            XCTAssertEqual(nonMotion(out), nonMotion(batch), "non-motion subsequence preserved exactly")
            XCTAssertFalse(hasAdjacentSameClassMotion(out), "no two adjacent same-class motion survive")
        }
    }

    // MARK: helpers

    private func isMove(_ e: InputEvent) -> Bool { if case .mouseMove = e { return true }
        return false
    }

    private func isDrag(_ e: InputEvent) -> Bool { if case .mouseDrag = e { return true }
        return false
    }

    private func nonMotion(_ events: [InputEvent]) -> [InputEvent] { events.filter { !isMove($0) && !isDrag($0) } }
    private func hasAdjacentSameClassMotion(_ events: [InputEvent]) -> Bool {
        for i in 1..<max(1, events.count) where i < events.count {
            if isMove(events[i]), isMove(events[i - 1]) { return true }
            if isDrag(events[i]), isDrag(events[i - 1]) { return true }
        }
        return false
    }
}

/// Deterministic RNG so the fuzz invariants reproduce exactly (SplitMix64).
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
