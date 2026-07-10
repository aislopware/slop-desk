import SlopDeskClient
import SlopDeskTerminal
import XCTest
@testable import SlopDeskWorkspaceCore

/// Byte-exact pins for the replay ring's FIFO whole-chunk eviction semantics, written BEFORE the
/// lazy-compaction refactor (index-cursor head + amortized bulk `removeFirst`, the
/// `MuxChannelSession.fifoHead` / `FrameDecoder.compactConsumed` idiom) so the refactor can be
/// proven byte-identical. Every test asserts the EXACT retained byte stream via the replay seam
/// (`attachSurface` on a fresh recording surface feeds `[DECSTR] + retained chunks` in FIFO order),
/// which is the only consumer of the ring's contents.
@MainActor
final class TerminalViewModelRingCompactionTests: XCTestCase {
    /// Records EACH `feed(_:)` as a separate element so replay chunk boundaries + ordering (and the
    /// DECSTR prefix) are observable.
    private final class RecordingSurface: TerminalSurface, @unchecked Sendable {
        var feeds: [Data] = []
        func feed(_ bytes: Data) { feeds.append(bytes) }
        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}
        var onWrite: ((Data) -> Void)?
    }

    /// DECSTR — Soft Terminal Reset (`ESC [ ! p`), the replay prefix.
    private static let decstr = Data([0x1B, 0x5B, 0x21, 0x70])

    /// Independent spec of the ring's retention policy: append whole chunks, evict whole OLDEST
    /// chunks while over `cap`, but never evict the last remaining chunk (a single over-cap chunk
    /// is kept). The production code must retain exactly this, before and after the refactor.
    private func expectedRetained(after chunks: [Data], cap: Int) -> [Data] {
        var retained: [Data] = []
        var bytes = 0
        for chunk in chunks {
            retained.append(chunk)
            bytes += chunk.count
            while bytes > cap, retained.count > 1 {
                bytes -= retained.removeFirst().count
            }
        }
        return retained
    }

    /// Uniquely-patterned 5-byte chunk (`c000|` … `c999|`) so any off-by-one / reorder / dropped
    /// chunk shows up as a byte mismatch, not just a count mismatch.
    private func patterned(_ i: Int) -> Data {
        Data(String(format: "c%03d|", i).utf8)
    }

    /// Feeds `chunks` one-by-one (the interactive-typing shape), then asserts the ring's exact
    /// retained stream against the independent spec via the replay seam.
    private func assertRetainedExactly(
        chunks: [Data],
        cap: Int,
        into model: TerminalViewModel,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        model.maxRingBytes = cap
        for chunk in chunks {
            model.ingestOutput(chunk)
        }
        let expected = expectedRetained(after: chunks, cap: cap)
        XCTAssertEqual(
            model.ringByteCount,
            expected.reduce(0) { $0 + $1.count },
            "ringByteCount must equal the retained bytes — \(message)",
            file: file,
            line: line,
        )
        let surface = RecordingSurface()
        model.attachSurface(surface)
        XCTAssertEqual(
            surface.feeds,
            [Self.decstr] + expected,
            message,
            file: file,
            line: line,
        )
    }

    // MARK: Byte-exact retention pins (green pre- AND post-refactor)

    func testManySmallChunksOverCapRetainExactFIFOSuffix() {
        // 100 × 5-byte chunks against a 64-byte cap → steady state holds the newest 12 whole
        // chunks (60 bytes); everything older was evicted whole, in FIFO order.
        let chunks = (0..<100).map { patterned($0) }
        assertRetainedExactly(
            chunks: chunks,
            cap: 64,
            into: TerminalViewModel(),
            "many small chunks over cap: exact FIFO suffix retained",
        )
        // Non-tautology anchor: the spec says exactly chunks 88…99 survive.
        XCTAssertEqual(
            expectedRetained(after: chunks, cap: 64),
            (88..<100).map { patterned($0) },
        )
    }

    func testOneHugeChunkEvictsManySmallButIsItselfKept() {
        // Idle-typing steady state (many tiny chunks), then one chunk BIGGER than the whole cap
        // (`cat` of a file): every older chunk is evicted in one synchronous ingest, but the
        // over-cap chunk itself is KEPT (never evict the last remaining chunk).
        let huge = Data(repeating: 0x58, count: 100) // 100 > cap 64
        let chunks = (0..<20).map { patterned($0) } + [huge]
        let model = TerminalViewModel()
        assertRetainedExactly(
            chunks: chunks,
            cap: 64,
            into: model,
            "a chunk larger than the cap evicts all older chunks and survives alone",
        )
        XCTAssertEqual(expectedRetained(after: chunks, cap: 64), [huge])
        XCTAssertEqual(model.ringByteCount, 100, "the sole over-cap chunk is retained in full")
    }

    func testLargeChunkPartiallyEvictsAndCoexistsWithSurvivingSmallChunks() {
        // A large-but-under-cap chunk evicts only as many oldest whole chunks as needed; the
        // newest small chunks that still fit survive alongside it.
        let large = Data(repeating: 0x59, count: 50) // 50 < cap 64
        let chunks = (0..<20).map { patterned($0) } + [large]
        assertRetainedExactly(
            chunks: chunks,
            cap: 64,
            into: TerminalViewModel(),
            "large under-cap chunk: partial whole-chunk eviction, exact survivors",
        )
        XCTAssertEqual(
            expectedRetained(after: chunks, cap: 64),
            [patterned(18), patterned(19), large],
            "12 smalls at steady state + 50 = 110 → evict 10 oldest wholes → 60 ≤ 64",
        )
    }

    func testInterleavedSizesRetainExactStream() {
        // Mixed tiny/medium/large chunks with unique fill bytes — exercises evictions triggered
        // at varying depths so any head-cursor bookkeeping error surfaces as a byte diff.
        var chunks: [Data] = []
        let sizes = [3, 17, 1, 40, 5, 5, 5, 29, 2, 63, 1, 1, 8, 33, 12, 5, 44, 7, 19, 60]
        for (i, size) in sizes.enumerated() {
            chunks.append(Data(repeating: UInt8(0x20 + i), count: size))
        }
        assertRetainedExactly(
            chunks: chunks,
            cap: 64,
            into: TerminalViewModel(),
            "interleaved sizes: exact retained stream",
        )
    }

    // MARK: Clear/reset paths (head cursor must reset wherever the ring is cleared)

    func testRingClearedByResetThenRefilledReplaysOnlyNewBytes() {
        let model = TerminalViewModel()
        model.maxRingBytes = 64
        // Fill well past the cap so evictions have happened (post-refactor: head cursor > 0).
        for i in 0..<50 {
            model.ingestOutput(patterned(i))
        }
        XCTAssertEqual(model.ringByteCount, 60, "precondition: at steady state under the cap")

        model.reset() // deliberate fresh connect target — ring must be emptied
        XCTAssertEqual(model.ringByteCount, 0)

        // Refill and confirm the replay contains ONLY the new session's bytes, exact and ordered.
        let refill = [Data("new-1|".utf8), Data("new-2|".utf8)]
        for chunk in refill {
            model.ingestOutput(chunk)
        }
        let surface = RecordingSurface()
        model.attachSurface(surface)
        XCTAssertEqual(
            surface.feeds,
            [Self.decstr] + refill,
            "post-reset refill replays only the new bytes",
        )
    }

    func testFreshSessionWipeAfterEvictionsDropsRingThenRetainsOnlyFreshBytes() {
        let model = TerminalViewModel()
        model.maxRingBytes = 64
        let live = RecordingSurface()
        model.attachSurface(live)
        // Dead session: enough output that evictions occurred before the drop.
        for i in 0..<50 {
            model.ingestOutput(patterned(i))
        }

        model.markReconnecting() // transport drop → the next output belongs to a NEW shell

        model.ingestOutput(Data("FRESH|".utf8)) // consumes the one-shot wipe (RIS + ring drop)
        XCTAssertEqual(
            model.ringByteCount,
            "FRESH|".count,
            "the dead session's ring is dropped; only the fresh chunk is retained",
        )
        // And more fresh output keeps normal FIFO accounting after the wipe.
        model.ingestOutput(Data("MORE|".utf8))
        let rebuilt = RecordingSurface()
        model.attachSurface(rebuilt)
        XCTAssertEqual(
            rebuilt.feeds,
            [Self.decstr, Data("FRESH|".utf8), Data("MORE|".utf8)],
            "replay after the wipe = fresh session bytes only, FIFO order",
        )
    }

    func testEvictionsKeepWorkingAfterManyWipeRefillCycles() {
        // Repeated clear → refill-past-cap cycles: the head cursor must reset on every clear or
        // byte accounting / retention drifts across cycles.
        let model = TerminalViewModel()
        model.maxRingBytes = 64
        for cycle in 0..<5 {
            for i in 0..<40 {
                model.ingestOutput(patterned(cycle * 100 + i))
            }
            let expected = expectedRetained(after: (0..<40).map { patterned(cycle * 100 + $0) }, cap: 64)
            let surface = RecordingSurface()
            model.attachSurface(surface)
            XCTAssertEqual(surface.feeds, [Self.decstr] + expected, "cycle \(cycle) retention exact")
            model.reset()
            XCTAssertEqual(model.ringByteCount, 0, "cycle \(cycle) reset clears accounting")
        }
    }

    // MARK: Perf shape (coarse — generous bound, no tight timing)

    /// The finding: `ring.removeFirst()` is an O(count) memmove per evicted chunk, so interactive
    /// tiny chunks at steady state pay O(ring.count) per ingest and a big chunk after idle typing
    /// pays O(n²) in ONE synchronous main-actor call, directly ahead of `feedBatch`. With the
    /// index-cursor head this whole sequence is amortized O(total bytes). The bound is deliberately
    /// generous (the fixed shape completes in well under a second; the quadratic shape takes many
    /// seconds) — a coarse shape check, not a benchmark.
    func testIngestPerfShapeManyTinyChunksThenHugeChunk() {
        let model = TerminalViewModel()
        model.maxRingBytes = 256 * 1024 // the production default, explicit for the math below
        let tiny = Data([0x2E, 0x2E]) // 2 bytes → steady state ≈ 131k retained chunks
        let huge = Data(repeating: 0x2E, count: 256 * 1024) // evicts the entire backlog in one call

        let start = ContinuousClock.now
        for _ in 0..<150_000 {
            model.ingestOutput(tiny)
        }
        model.ingestOutput(huge)
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(model.ringByteCount, huge.count, "the huge chunk evicted every tiny chunk")
        XCTAssertLessThan(
            elapsed,
            .seconds(3),
            "150k tiny ingests + one cap-sized chunk must not go quadratic on the main actor",
        )
    }
}
