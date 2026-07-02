import AislopdeskProtocol
import Foundation
import XCTest
@testable import AislopdeskHost

/// WB1 — the host ``CommandBlockTracker``: the live glue between the pure ``CommandBlockSegmenter``
/// and the wire. Proves it (a) emits a type-28 `commandBlock` METADATA update per block create /
/// update / complete, DEDUPED; (b) retains each completed block's output in a BOUNDED ring and
/// serves it as type-29 `blockOutput`; (c) evicts oldest-first under both bounds; (d) returns an
/// EMPTY response for an evicted / unknown index — never traps.
///
/// Non-tautological: the OSC 133 fixtures are built from STRING literals, and the asserts pin the
/// extracted metadata + served bytes back to those literals, never to the tracker's own output.
final class CommandBlockTrackerTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"

    private func a() -> String { "\(ESC)]133;A\(BEL)" }
    private func b() -> String { "\(ESC)]133;B\(BEL)" }
    private func c() -> String { "\(ESC)]133;C\(BEL)" }
    private func d(_ exit: Int) -> String { "\(ESC)]133;D;\(exit)\(BEL)" }
    private func cycle(prompt: String, command: String, output: String, exit: Int) -> String {
        a() + prompt + b() + command + c() + output + d(exit)
    }

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    /// One `commandBlock` metadata update extracted from an emit (named so asserts read clearly).
    private struct Meta {
        var index: UInt32
        var exit: Int32?
        var dur: UInt32?
        var complete: Bool
        var outLen: UInt32
        var cmd: String
        var ordinal: UInt32
    }

    /// All `commandBlock` metadata emitted by ingesting `stream` in one chunk.
    private func metas(_ stream: String, _ tracker: inout CommandBlockTracker) -> [Meta] {
        tracker.ingest(bytes(stream)).compactMap {
            guard case let .commandBlock(index, exit, dur, complete, outLen, cmd, ordinal) = $0
            else { return nil }
            return Meta(
                index: index, exit: exit, dur: dur, complete: complete, outLen: outLen, cmd: cmd,
                ordinal: ordinal,
            )
        }
    }

    // MARK: 1. A completed command → a complete type-28 metadata update

    func testCompletedCommandEmitsMetadata() {
        var tracker = CommandBlockTracker()
        let m = metas(cycle(prompt: "$ ", command: "echo hi", output: "hi\n", exit: 0), &tracker)
        // At least one COMPLETE metadata for index 0 pinned to the literal command + output length.
        let complete = m.filter(\.complete)
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(complete[0].index, 0)
        XCTAssertEqual(complete[0].cmd, "echo hi")
        XCTAssertEqual(complete[0].exit, 0)
        XCTAssertEqual(complete[0].outLen, 3) // "hi\n" = 3 bytes
    }

    // MARK: 2. A running command → a RUNNING (incomplete) metadata update

    func testRunningCommandEmitsIncompleteMetadata() {
        var tracker = CommandBlockTracker()
        // A→B→C→partial output, NO D yet.
        let m = metas(a() + "$ " + b() + "tail -f log" + c() + "line 1\n", &tracker)
        let running = m.filter { !$0.complete }
        XCTAssertEqual(running.last?.index, 0)
        XCTAssertEqual(running.last?.cmd, "tail -f log")
        XCTAssertNil(running.last?.exit)
        XCTAssertNil(running.last?.dur)
        XCTAssertEqual(running.last?.outLen, 7) // "line 1\n"
    }

    // MARK: 3. Dedup — a RUNNING block's per-chunk output growth does NOT re-emit; a real change does

    func testIdenticalMetadataNotReEmitted() {
        var tracker = CommandBlockTracker()
        // Open a RUNNING block (A→B→C, NO D) and emit its first running metadata.
        let opened = metas(a() + "$ " + b() + "tail -f log" + c() + "line 1\n", &tracker)
        XCTAssertEqual(opened.last(where: { !$0.complete })?.cmd, "tail -f log", "running block opened + emitted")

        // A 2nd chunk that adds NO new output and no new mark → the RUNNING block is unchanged →
        // NOTHING re-emitted. (This drives the dedup compare directly: without the #8 churn guard the
        // running block would re-emit on the previous chunk's outputLen alone — but here outputLen is
        // also unchanged, so even the un-fixed dedup must stay quiet; this is the floor.)
        let noChange = tracker.ingest(bytes("\u{1B}]0;a title\u{07}")) // a non-133 OSC = no block change
        XCTAssertTrue(commandBlocks(noChange).isEmpty, "running block unchanged → nothing re-emitted")

        // A chunk that GROWS the running block's output (more output bytes, still no D) must NOT
        // re-emit a type-28 — this is the #8 churn guard. Mutation test: if the guard is removed
        // (outputLen back in the running dedup key) this WILL emit and the assert fails.
        let grew = tracker.ingest(bytes("line 2\n"))
        XCTAssertTrue(
            commandBlocks(grew).isEmpty,
            "a running block's output growth must NOT churn the control channel (#8)",
        )

        // Completion (D arrives) IS a meaningful change → it DOES emit, with the final exit + length.
        let done = metas(d(0), &tracker)
        let completed = done.filter(\.complete)
        XCTAssertEqual(completed.count, 1, "completion always emits a fresh type-28")
        XCTAssertEqual(completed[0].cmd, "tail -f log")
        XCTAssertEqual(completed[0].exit, 0)
        XCTAssertEqual(completed[0].outLen, 14, "final outputLen = 'line 1\\nline 2\\n' = 14 bytes")
    }

    /// All `commandBlock` metadata in a raw `[WireMessage]` batch (for chunks ingested directly).
    private func commandBlocks(_ messages: [WireMessage]) -> [Meta] {
        messages.compactMap {
            guard case let .commandBlock(index, exit, dur, complete, outLen, cmd, ordinal) = $0
            else { return nil }
            return Meta(
                index: index, exit: exit, dur: dur, complete: complete, outLen: outLen, cmd: cmd,
                ordinal: ordinal,
            )
        }
    }

    // MARK: 3b. Prompt-redraw storm — no phantom "running" metadata on the control channel

    func testPromptRedrawStormEmitsNoPhantomRunningBlocks() {
        var tracker = CommandBlockTracker()
        // An idle prompt whose B mark re-fires on three reset-prompt redraws (one per resize) must
        // NOT emit ANY commandBlock metadata: nothing is running, and each redraw is the SAME prompt.
        let idle = metas(a() + "$ " + b() + b() + b() + b(), &tracker)
        XCTAssertTrue(idle.isEmpty, "an idle prompt + redraws must emit no phantom running blocks")

        // Now a real command runs. It surfaces as running (at C) then completes (at D) — exactly one
        // block, index 0 (the redraws never consumed an index).
        let done = metas("ls" + c() + "x\n" + d(0), &tracker)
        XCTAssertEqual(Set(done.map(\.index)), [0], "the real command keeps index 0 despite the redraws")
        let complete = done.filter(\.complete)
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(complete[0].cmd, "ls")
        XCTAssertEqual(complete[0].exit, 0)
    }

    // MARK: 3bb. Interrupted (nested-shell) block — the close still emits + resync finalizes it

    // A deterministic clock so the interrupt-close duration is a pinned value, not wall-clock noise.
    private final class TestClock {
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        func date() -> Date { now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    func testInterruptedRunningBlockEmitsFinalUpdate() {
        // Bug 3: a running block (surfaced at C) interrupted by a fresh prompt (A/B with no D — a
        // nested shell / ssh whose inner shell emits its own OSC-133) is closed INCOMPLETE on the
        // host. The close must STILL emit a type-28 so the client's spinner can end. Before the fix
        // the segmenter closed it with a nil duration, so the tracker's dedup saw "both running" with
        // only outputLen changed and suppressed the emit — the client was stranded on "running…".
        let clock = TestClock()
        var tracker = CommandBlockTracker(segmenter: CommandBlockSegmenter(clock: clock.date))
        // Open + run a block to .output (surfaces as running).
        _ = tracker.ingest(bytes(a() + "$ " + b() + "ssh host" + c() + "partial\n"))
        clock.advance(3.0)
        // A fresh prompt A interrupts it (no D).
        let onInterrupt = commandBlocks(tracker.ingest(bytes(a())))
        XCTAssertEqual(onInterrupt.count, 1, "the interrupt-close must emit a final type-28, not be deduped away")
        XCTAssertEqual(onInterrupt[0].index, 0)
        XCTAssertEqual(onInterrupt[0].cmd, "ssh host")
        XCTAssertFalse(onInterrupt[0].complete)
        XCTAssertEqual(onInterrupt[0].dur, 3000, "the close stamps the C→interrupt duration so it is distinct")

        // And a reattach backfill carries the FINALIZED (duration-stamped) metadata — not stuck as a
        // bare running row that the client would re-spin.
        let snap = commandBlocks(tracker.snapshotForResync())
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].index, 0)
        XCTAssertEqual(snap[0].dur, 3000, "resync no longer resurrects the stuck running state")
    }

    // MARK: 3c. Reattach backfill — snapshotForResync re-emits every held block's metadata in order

    func testSnapshotForResyncReEmitsAllHeldBlocksInIndexOrder() {
        var tracker = CommandBlockTracker()
        // Three completed commands + one still-running command (index 3, no D).
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "cmd0", output: "a\n", exit: 0)))
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "cmd1", output: "b\n", exit: 1)))
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "cmd2", output: "c\n", exit: 0)))
        _ = tracker.ingest(bytes(a() + "$ " + b() + "cmd3-running" + c() + "partial\n"))

        let snap = commandBlocks(tracker.snapshotForResync())
        // One metadata per known block (0..3), ASCENDING index order — this is what rebuilds a
        // reattaching client's navigator.
        XCTAssertEqual(snap.map(\.index), [0, 1, 2, 3])
        // Pinned to the literal commands + exit codes (never to the tracker's own output).
        XCTAssertEqual(snap.map(\.cmd), ["cmd0", "cmd1", "cmd2", "cmd3-running"])
        XCTAssertEqual(snap[0].exit, 0)
        XCTAssertEqual(snap[1].exit, 1)
        XCTAssertEqual(snap[2].exit, 0)
        // The completed blocks are complete; the still-running block is NOT.
        XCTAssertEqual(snap.map(\.complete), [true, true, true, false])
        XCTAssertNil(snap[3].exit, "a running block carries no exit code in the backfill")
    }

    func testSnapshotForResyncOmitsEvictedBlocks() {
        var tracker = CommandBlockTracker(maxBlocks: 2)
        for i in 0..<4 {
            _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "cmd\(i)", output: "o\n", exit: 0)))
        }
        // Only the last two blocks survive the ring; the backfill must not resurrect evicted ones.
        let snap = commandBlocks(tracker.snapshotForResync())
        XCTAssertEqual(snap.map(\.index), [2, 3])
        XCTAssertEqual(snap.map(\.cmd), ["cmd2", "cmd3"])
    }

    func testSnapshotForResyncEmptyWhenNoBlocks() {
        var tracker = CommandBlockTracker()
        XCTAssertTrue(tracker.snapshotForResync().isEmpty, "a tracker that saw no commands backfills nothing")
    }

    // MARK: 4. Serve the retained output for a completed block (type 29)

    func testServeOutputReturnsRetainedBytes() {
        var tracker = CommandBlockTracker()
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "cat f", output: "alpha\nbeta\n", exit: 0)))
        guard case let .blockOutput(index, output) = tracker.serveOutput(index: 0) else {
            XCTFail("expected blockOutput")
            return
        }
        XCTAssertEqual(index, 0)
        // Pinned to the literal output fed for that command.
        XCTAssertEqual(String(data: output, encoding: .utf8), "alpha\nbeta\n")
    }

    func testServeUnknownIndexReturnsEmptyNotTrap() {
        var tracker = CommandBlockTracker()
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "ls", output: "x\n", exit: 0)))
        guard case let .blockOutput(index, output) = tracker.serveOutput(index: 999) else {
            XCTFail("expected blockOutput")
            return
        }
        XCTAssertEqual(index, 999)
        XCTAssertTrue(output.isEmpty, "unknown index → empty output, never a trap")
    }

    func testRawControlSequencesPreservedInServedOutput() {
        var tracker = CommandBlockTracker()
        let colored = "\(ESC)[31mRED\(ESC)[0m\n"
        _ = tracker.ingest(bytes(a() + "$ " + b() + "ls --color" + c() + colored + d(0)))
        guard case let .blockOutput(_, output) = tracker.serveOutput(index: 0) else {
            XCTFail("expected blockOutput")
            return
        }
        XCTAssertEqual(String(data: output, encoding: .utf8), colored)
        XCTAssertTrue(output.contains(0x1B), "ESC bytes preserved verbatim")
    }

    // MARK: 5. Ring eviction — oldest-first under the block-COUNT bound

    func testRingEvictsOldestPastBlockCap() {
        var tracker = CommandBlockTracker(maxBlocks: 3)
        // Run 5 commands index 0..4; only the last 3 (2,3,4) stay retained.
        for i in 0..<5 {
            _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "cmd\(i)", output: "out\(i)\n", exit: 0)))
        }
        XCTAssertEqual(tracker.retainedIndicesForTesting, [2, 3, 4])
        // Evicted blocks serve empty; retained ones serve their bytes.
        guard case let .blockOutput(_, evicted) = tracker.serveOutput(index: 0) else { XCTFail()
            return
        }
        XCTAssertTrue(evicted.isEmpty, "evicted block 0 → empty")
        guard case let .blockOutput(_, kept) = tracker.serveOutput(index: 4) else { XCTFail()
            return
        }
        XCTAssertEqual(String(data: kept, encoding: .utf8), "out4\n")
    }

    // MARK: 6. Ring eviction — oldest-first under the total-BYTES bound

    func testRingEvictsOldestPastByteCap() {
        // Byte cap of 10; each command outputs 8 bytes ("xxxxxxx\n") so two blocks (16B) exceed it.
        var tracker = CommandBlockTracker(maxBlocks: 100, maxTotalOutputBytes: 10)
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "c0", output: "AAAAAAA\n", exit: 0)))
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "c1", output: "BBBBBBB\n", exit: 0)))
        // 8 + 8 = 16 > 10 → oldest (block 0) evicted; block 1 (8B ≤ 10) kept.
        XCTAssertEqual(tracker.retainedIndicesForTesting, [1])
        XCTAssertLessThanOrEqual(tracker.totalOutputBytesForTesting, 10)
        guard case let .blockOutput(_, evicted) = tracker.serveOutput(index: 0) else { XCTFail()
            return
        }
        XCTAssertTrue(evicted.isEmpty)
    }

    func testByteCapKeepsAtLeastTheNewestBlock() {
        // A single block whose output alone exceeds the byte cap is still retained + servable.
        var tracker = CommandBlockTracker(maxBlocks: 100, maxTotalOutputBytes: 4)
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "big", output: "0123456789\n", exit: 0)))
        XCTAssertEqual(tracker.retainedIndicesForTesting, [0])
        guard case let .blockOutput(_, output) = tracker.serveOutput(index: 0) else { XCTFail()
            return
        }
        XCTAssertEqual(String(data: output, encoding: .utf8), "0123456789\n")
    }

    // MARK: 7. Chunk-boundary invariance — split anywhere = same retained output

    func testChunkSplitDoesNotChangeRetainedOutput() {
        let stream = cycle(prompt: "$ ", command: "echo one", output: "one\ntwo\n", exit: 0)
        let raw = Array(stream.utf8)

        var whole = CommandBlockTracker()
        _ = whole.ingest(Data(raw))

        var split = CommandBlockTracker()
        for byte in raw { _ = split.ingest(Data([byte])) } // one byte at a time

        guard case let .blockOutput(_, a) = whole.serveOutput(index: 0),
              case let .blockOutput(_, b) = split.serveOutput(index: 0)
        else { XCTFail()
            return
        }
        XCTAssertEqual(a, b)
        XCTAssertEqual(String(data: a, encoding: .utf8), "one\ntwo\n")
    }
}
