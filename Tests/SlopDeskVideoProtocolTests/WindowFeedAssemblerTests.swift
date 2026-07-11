import XCTest
@testable import SlopDeskVideoProtocol

/// PURE chunk-assembly rules (docs/45): agree-on-chunkCount, idempotent duplicates, bounded partial
/// state, completion exactly once. The loss-model counterpart of `FrameReassemblerTests`.
final class WindowFeedAssemblerTests: XCTestCase {
    private func record(_ id: UInt32) -> HostWindowRecord {
        HostWindowRecord(
            windowID: id, widthPt: 100, heightPt: 100, flags: [.onScreen], displayIndex: 0,
            bundleID: "b", appName: "a", title: "t\(id)",
        )
    }

    func testSingleChunkCompletesImmediately() {
        var assembler = WindowFeedAssembler()
        let done = assembler.fold(generation: 1, chunkIndex: 0, chunkCount: 1, records: [record(1)])
        XCTAssertEqual(done, .init(generation: 1, records: [record(1)]))
    }

    func testChunksAssembleInIndexOrderRegardlessOfArrivalOrder() {
        var assembler = WindowFeedAssembler()
        XCTAssertNil(assembler.fold(generation: 2, chunkIndex: 1, chunkCount: 2, records: [record(2)]))
        let done = assembler.fold(generation: 2, chunkIndex: 0, chunkCount: 2, records: [record(1)])
        XCTAssertEqual(done?.records, [record(1), record(2)], "chunk order, not arrival order")
    }

    func testDuplicateChunksAreIdempotent() {
        // The host dup-sends ×2 — a repeat of an already-held chunk must not complete a generation
        // early or corrupt it.
        var assembler = WindowFeedAssembler()
        XCTAssertNil(assembler.fold(generation: 3, chunkIndex: 0, chunkCount: 2, records: [record(1)]))
        XCTAssertNil(assembler.fold(generation: 3, chunkIndex: 0, chunkCount: 2, records: [record(1)]))
        let done = assembler.fold(generation: 3, chunkIndex: 1, chunkCount: 2, records: [record(2)])
        XCTAssertEqual(done?.records, [record(1), record(2)])
    }

    func testChunkCountDisagreementDiscardsTheGeneration() {
        var assembler = WindowFeedAssembler()
        XCTAssertNil(assembler.fold(generation: 4, chunkIndex: 0, chunkCount: 2, records: [record(1)]))
        // Same generation now claims 3 chunks: corrupt — the whole generation is dropped…
        XCTAssertNil(assembler.fold(generation: 4, chunkIndex: 0, chunkCount: 3, records: [record(9)]))
        // …so completing the ORIGINAL 2-chunk shape no longer completes anything (state is gone).
        XCTAssertNil(assembler.fold(generation: 4, chunkIndex: 1, chunkCount: 2, records: [record(2)]))
    }

    func testInterleavedGenerationsCompleteIndependently() {
        var assembler = WindowFeedAssembler()
        XCTAssertNil(assembler.fold(generation: 5, chunkIndex: 0, chunkCount: 2, records: [record(1)]))
        XCTAssertNil(assembler.fold(generation: 6, chunkIndex: 0, chunkCount: 2, records: [record(3)]))
        XCTAssertEqual(
            assembler.fold(generation: 6, chunkIndex: 1, chunkCount: 2, records: [record(4)])?.generation,
            6,
        )
        XCTAssertEqual(
            assembler.fold(generation: 5, chunkIndex: 1, chunkCount: 2, records: [record(2)])?.generation,
            5,
            "the older generation still completes — the LOOP decides which snapshot wins, not the assembler",
        )
    }

    func testPartialMapIsBoundedByEvictingTheOldest() {
        var assembler = WindowFeedAssembler()
        for gen in 1...UInt32(WindowFeedAssembler.maxPartialGenerations + 1) {
            XCTAssertNil(assembler.fold(generation: gen, chunkIndex: 0, chunkCount: 2, records: []))
        }
        // Generation 1 was evicted to admit the newest — completing it now does nothing…
        XCTAssertNil(assembler.fold(generation: 1, chunkIndex: 1, chunkCount: 2, records: [record(1)]))
        // …while the youngest still completes.
        let youngest = UInt32(WindowFeedAssembler.maxPartialGenerations + 1)
        XCTAssertNotNil(assembler.fold(generation: youngest, chunkIndex: 1, chunkCount: 2, records: []))
    }

    func testHostileRecordFloodDiscardsTheGeneration() {
        var assembler = WindowFeedAssembler()
        let flood = (0..<300).map { record(UInt32($0)) }
        XCTAssertNil(assembler.fold(generation: 7, chunkIndex: 0, chunkCount: 2, records: flood))
        XCTAssertNil(
            assembler.fold(generation: 7, chunkIndex: 1, chunkCount: 2, records: flood),
            "600 records exceeds the accumulator cap — hostile padding never reaches the store",
        )
    }

    func testResetDropsAllPartials() {
        var assembler = WindowFeedAssembler()
        XCTAssertNil(assembler.fold(generation: 8, chunkIndex: 0, chunkCount: 2, records: [record(1)]))
        assembler.reset()
        XCTAssertNil(
            assembler.fold(generation: 8, chunkIndex: 1, chunkCount: 2, records: [record(2)]),
            "a reset round starts empty — the stale half never completes",
        )
    }
}
