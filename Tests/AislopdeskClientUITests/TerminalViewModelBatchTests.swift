import AislopdeskClient
import AislopdeskTerminal
import XCTest
@testable import AislopdeskClientUI

/// Batch-drain ingest tests (`TerminalViewModel.ingestBatch`): the inbound path's analogue
/// of the OUT-path coalescer. Pins the load-bearing properties of the batch design:
/// byte-identity with per-chunk ingest, ONE renderer flush per budget pass, chunk-granular
/// ring retention, `Task.yield()` interleaving between over-budget passes, and the
/// fresh-session wipe ordering (RIS strictly before the first batch byte).
@MainActor
final class TerminalViewModelBatchTests: XCTestCase {
    /// Surface seam that records each write AND each flush boundary: `feed` = one write +
    /// one flush; `feedBatch` = N writes + one flush (mirrors `GhosttySurface`'s override).
    private final class FlushRecordingSurface: TerminalSurface, @unchecked Sendable {
        var writes: [Data] = []
        var flushes = 0
        func feed(_ bytes: Data) {
            writes.append(bytes)
            flushes += 1
        }

        func feedBatch(_ chunks: ArraySlice<Data>) {
            writes.append(contentsOf: chunks)
            flushes += 1
        }

        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}
        var onWrite: ((Data) -> Void)?
    }

    /// RIS — Reset to Initial State (`ESC c`), the fresh-session wipe prefix.
    private static let ris = Data([0x1B, 0x63])

    func testBatchMatchesPerChunkIngestByteForByte() async {
        let chunks = [Data("abc".utf8), Data("defg".utf8), Data("h".utf8)]

        let single = FlushRecordingSurface()
        let singleModel = TerminalViewModel(surface: single)
        for chunk in chunks { singleModel.ingestOutput(chunk) }

        let batched = FlushRecordingSurface()
        let batchedModel = TerminalViewModel(surface: batched)
        await batchedModel.ingestBatch(chunks)

        XCTAssertEqual(
            batched.writes.reduce(Data(), +), single.writes.reduce(Data(), +),
            "batched ingest must deliver byte-identical output in order",
        )
        XCTAssertEqual(batched.writes, chunks, "wire-chunk write granularity is preserved")
        XCTAssertEqual(
            batchedModel.ringByteCount,
            singleModel.ringByteCount,
            "ring retention is identical between the two paths",
        )
        XCTAssertEqual(batchedModel.bytesReceived, singleModel.bytesReceived)
    }

    func testUnderBudgetBatchFlushesExactlyOnce() async {
        let surface = FlushRecordingSurface()
        let model = TerminalViewModel(surface: surface)
        let chunks = (0..<10).map { Data("chunk\($0)".utf8) } // tiny — far under budget
        await model.ingestBatch(chunks)
        XCTAssertEqual(surface.flushes, 1, "one renderer flush for the whole under-budget batch")
        XCTAssertEqual(surface.writes, chunks)
    }

    func testOverBudgetBatchSplitsAtChunkBoundariesOneFlushPerPass() async {
        let surface = FlushRecordingSurface()
        let model = TerminalViewModel(surface: surface)
        // 3 chunks of ~budget/2 each → passes accumulate until >= budget: pass1 = 2 chunks,
        // pass2 = 1 chunk. Chunks must never split.
        let half = TerminalViewModel.ingestByteBudget / 2
        let chunks = [
            Data(repeating: 0x61, count: half),
            Data(repeating: 0x62, count: half),
            Data(repeating: 0x63, count: half),
        ]
        await model.ingestBatch(chunks)
        XCTAssertEqual(surface.flushes, 2, "budget split → two passes, one flush each")
        XCTAssertEqual(surface.writes, chunks, "chunks are never split or reordered")
        XCTAssertEqual(model.bytesReceived, half * 3)
    }

    func testOverBudgetBatchYieldsBetweenPasses() async {
        let surface = FlushRecordingSurface()
        let model = TerminalViewModel(surface: surface)
        let chunks = [
            Data(repeating: 0x61, count: TerminalViewModel.ingestByteBudget),
            Data(repeating: 0x62, count: TerminalViewModel.ingestByteBudget),
        ]
        // A MainActor marker enqueued BEFORE the drain starts: the drain's between-pass
        // Task.yield() must let it run before the final pass completes — proving input
        // events / display-link work interleave with a multi-pass backlog.
        var markerRan = false
        var flushesWhenMarkerRan = -1
        Task { @MainActor in
            markerRan = true
            flushesWhenMarkerRan = surface.flushes
        }
        await model.ingestBatch(chunks)
        XCTAssertTrue(markerRan, "marker task interleaved with the multi-pass drain (Task.yield ran)")
        XCTAssertLessThan(
            flushesWhenMarkerRan,
            2,
            "marker ran BEFORE the drain finished — the backlog did not monopolize the main actor",
        )
        XCTAssertEqual(surface.flushes, 2)
    }

    func testFreshSessionWipePrecedesFirstBatchByte() async {
        let surface = FlushRecordingSurface()
        let model = TerminalViewModel(surface: surface)
        model.ingestOutput(Data("old-session".utf8))
        model.markReconnecting()
        surface.writes.removeAll()

        await model.ingestBatch([Data("new".utf8), Data("shell".utf8)])
        XCTAssertEqual(
            surface.writes.first,
            Self.ris,
            "RIS hard reset is fed strictly before the fresh session's first byte",
        )
        XCTAssertEqual(surface.writes.dropFirst().reduce(Data(), +), Data("newshell".utf8))
        // Ring was wiped before retaining the new chunks: only the fresh bytes remain.
        XCTAssertEqual(model.ringByteCount, "newshell".count)
    }

    func testEmptyBatchIsANoOp() async {
        let surface = FlushRecordingSurface()
        let model = TerminalViewModel(surface: surface)
        await model.ingestBatch([])
        XCTAssertEqual(surface.flushes, 0)
        XCTAssertTrue(surface.writes.isEmpty)
        XCTAssertEqual(model.bytesReceived, 0)
    }

    func testAttachSurfaceReplaysAsOneBatch() {
        let model = TerminalViewModel()
        model.ingestOutput(Data("aa".utf8))
        model.ingestOutput(Data("bb".utf8))
        let rebuilt = FlushRecordingSurface()
        model.attachSurface(rebuilt)
        XCTAssertEqual(rebuilt.flushes, 1, "replay is one batch → one renderer flush")
        XCTAssertEqual(
            rebuilt.writes,
            [Data([0x1B, 0x5B, 0x21, 0x70]), Data("aa".utf8), Data("bb".utf8)],
            "DECSTR prefix then the ring in FIFO order",
        )
    }

    // MARK: Render-side backpressure (docs/31 #5 — async-feed surfaces)

    /// Surface whose ``feedBackpressure()`` suspends until the test releases it —
    /// models GhosttySurface's serial feed queue above high water.
    private final class BackpressureSurface: TerminalSurface, FeedBackpressuring, @unchecked Sendable {
        var writes: [Data] = []
        var flushes = 0
        var backpressureCalls = 0
        private var parked: [CheckedContinuation<Void, Never>] = []
        var gateOpen = false

        func feed(_ bytes: Data) { writes.append(bytes)
            flushes += 1
        }

        func feedBatch(_ chunks: ArraySlice<Data>) {
            writes.append(contentsOf: chunks)
            flushes += 1
        }

        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}
        var onWrite: ((Data) -> Void)?

        func feedBackpressure() async {
            backpressureCalls += 1
            if gateOpen { return }
            await withCheckedContinuation { parked.append($0) }
        }

        func release() {
            gateOpen = true
            let toResume = parked
            parked.removeAll()
            for continuation in toResume { continuation.resume() }
        }
    }

    func testIngestAwaitsBackpressureBeforeEveryPass() async {
        let surface = BackpressureSurface()
        let model = TerminalViewModel(surface: surface)
        let chunks = [
            Data(repeating: 0x61, count: TerminalViewModel.ingestByteBudget),
            Data(repeating: 0x62, count: TerminalViewModel.ingestByteBudget),
        ]
        let ingest = Task { @MainActor in await model.ingestBatch(chunks) }
        // Parked before the FIRST pass: nothing fed while the surface is above water.
        await Task.megaYield()
        XCTAssertEqual(surface.flushes, 0, "no pass ran while backpressure parked")
        XCTAssertEqual(surface.backpressureCalls, 1)

        surface.release()
        await ingest.value
        XCTAssertEqual(surface.flushes, 2, "both passes ran after release")
        XCTAssertEqual(surface.writes, chunks)
        XCTAssertEqual(surface.backpressureCalls, 2, "backpressure awaited before EVERY pass")
    }

    func testSynchronousSurfacesUnaffectedByBackpressureHook() async {
        // The default no-op keeps plain surfaces exactly as before (covered implicitly
        // by every other test in this file using FlushRecordingSurface — this pins the
        // default's existence explicitly).
        let surface = FlushRecordingSurface()
        let model = TerminalViewModel(surface: surface)
        await model.ingestBatch([Data("ok".utf8)])
        XCTAssertEqual(surface.flushes, 1)
    }

    // MARK: Stale-batch guards after the backpressure park (review round)

    func testCancelledPumpParkedAtBackpressurePaintsNothing() async {
        let surface = BackpressureSurface()
        let model = TerminalViewModel(surface: surface)
        model.ingestOutput(Data("old".utf8))
        model.markReconnecting() // arm the one-shot wipe the dead pass must not consume
        surface.writes.removeAll()
        surface.flushes = 0

        let ingest = Task { @MainActor in
            await model.ingestBatch([Data("dead-session bytes".utf8)])
        }
        await Task.megaYield()
        XCTAssertEqual(surface.flushes, 0, "parked before the first pass")

        ingest.cancel() // teardown/reconnect replaced this pump
        surface.release() // the gate drains; the resumed pump must bail
        await ingest.value
        XCTAssertEqual(surface.flushes, 0, "a cancelled pump paints NO pass after the park")
        XCTAssertTrue(surface.writes.isEmpty)
        // The wipe stays armed for the NEW session's first output.
        await model.ingestBatch([Data("new".utf8)])
        XCTAssertEqual(
            surface.writes.first,
            Self.ris,
            "the one-shot wipe survived the cancelled pump and fired for the new session",
        )
    }

    func testStaleEpochBatchDropsInsteadOfConsumingWipe() async {
        let surface = FlushRecordingSurface()
        let model = TerminalViewModel(surface: surface)
        model.ingestOutput(Data("old".utf8))
        let staleEpoch = model.sessionEpoch
        model.markReconnecting() // supervisor reconnect: pump NOT cancelled, epoch bumped
        surface.writes.removeAll()
        surface.flushes = 0

        await model.ingestBatch([Data("dead bytes taken before the drop".utf8)], epoch: staleEpoch)
        XCTAssertEqual(surface.flushes, 0, "stale-epoch batch dropped without painting")
        XCTAssertTrue(surface.writes.isEmpty)

        await model.ingestBatch([Data("fresh shell".utf8)], epoch: model.sessionEpoch)
        XCTAssertEqual(
            surface.writes.first,
            Self.ris,
            "the wipe was consumed by the NEW session's bytes, not the dead batch",
        )
        XCTAssertEqual(surface.writes.dropFirst().reduce(Data(), +), Data("fresh shell".utf8))
    }

    func testCurrentEpochBatchPaintsNormally() async {
        let surface = FlushRecordingSurface()
        let model = TerminalViewModel(surface: surface)
        await model.ingestBatch([Data("hello".utf8)], epoch: model.sessionEpoch)
        XCTAssertEqual(surface.writes, [Data("hello".utf8)])
    }
}

private extension Task where Success == Never, Failure == Never {
    /// Yields enough times for already-runnable MainActor work to complete — the
    /// parked-ingest assertions need the ingest Task to reach its first await.
    static func megaYield() async {
        for _ in 0..<20 { await yield() }
    }
}
