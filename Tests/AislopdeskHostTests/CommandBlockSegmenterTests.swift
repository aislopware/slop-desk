import Foundation
import XCTest
@testable import AislopdeskHost

/// SPIKE test suite for ``CommandBlockSegmenter`` — proves the host can segment the raw
/// OUTBOUND PTY byte stream into per-command Blocks from the OSC 133 A/B/C/D marks alone.
///
/// Non-tautological by construction: the fixtures are built from STRING literals (the
/// command text + the output text are written by hand), and the asserts pin the EXTRACTED
/// spans back to those literals — never to a recomputation of the segmenter's own output.
final class CommandBlockSegmenterTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"
    private let ST = "\u{1B}\\" // ESC \

    // MARK: Fixture builders (OSC 133 marks around literal text)

    private func a() -> String { "\(ESC)]133;A\(BEL)" }
    private func b() -> String { "\(ESC)]133;B\(BEL)" }
    private func c() -> String { "\(ESC)]133;C\(BEL)" }
    private func d(_ exit: Int? = nil) -> String {
        exit.map { "\(ESC)]133;D;\($0)\(BEL)" } ?? "\(ESC)]133;D\(BEL)"
    }

    /// A full prompt→command→output→done cycle: `A` <prompt> `B` <cmd> `C` <output> `D;exit`.
    private func cycle(prompt: String, command: String, output: String, exit: Int) -> String {
        a() + prompt + b() + command + c() + output + d(exit)
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func text(_ b: [UInt8]) -> String { String(bytes: b, encoding: .utf8) ?? "" }

    // A deterministic clock the segmenter reads on each `C`/`D`. `advance` moves it forward.
    private final class TestClock {
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        func date() -> Date { now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    // MARK: 1. Single command — text, output, exit all extracted

    func testSingleCommandExtractsTextOutputExit() {
        let stream = cycle(prompt: "user@host $ ", command: "echo hi", output: "hi\n", exit: 0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))

        XCTAssertEqual(blocks.count, 1)
        let block = blocks[0]
        XCTAssertEqual(block.index, 0)
        // Pinned to the literal "echo hi" (the prompt before B must NOT leak in).
        XCTAssertEqual(block.commandText, "echo hi")
        // Pinned to the literal "hi\n" (the prompt AND the command text must NOT leak in).
        XCTAssertEqual(text(block.output), "hi\n")
        XCTAssertEqual(block.exitCode, 0)
        XCTAssertTrue(block.complete)
        XCTAssertFalse(block.outputTruncated)
    }

    func testNonZeroExitCodeParsed() {
        let stream = cycle(prompt: "$ ", command: "false", output: "", exit: 1)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].exitCode, 1)
        XCTAssertEqual(blocks[0].commandText, "false")
        XCTAssertEqual(blocks[0].output, [])
    }

    func testExitCodeAbsentIsNil() {
        // `D` with no exit field → nil exit (not 0).
        let stream = a() + "$ " + b() + "ls" + c() + "a  b\n" + d(nil)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(blocks[0].exitCode)
        XCTAssertEqual(blocks[0].commandText, "ls")
        XCTAssertEqual(text(blocks[0].output), "a  b\n")
    }

    // MARK: 2. C→D duration via injected clock

    func testDurationMeasuredFromClock() {
        let clock = TestClock()
        var seg = CommandBlockSegmenter(clock: clock.date)
        // Feed up to C, then advance the clock 1.25s, then feed the rest.
        seg.ingest(bytes(a() + "$ " + b() + "sleep 1" + c()))
        clock.advance(1.25)
        let completed = seg.ingest(bytes("output\n" + d(0)))

        XCTAssertEqual(completed.count, 1)
        // 1.25s → exactly 1250 ms (pinned to the injected advance, not a recomputation).
        XCTAssertEqual(completed[0].durationMS, 1250)
        XCTAssertEqual(completed[0].commandText, "sleep 1")
    }

    // MARK: 3. Multi-command session

    func testMultiCommandSession() {
        let stream =
            cycle(prompt: "$ ", command: "pwd", output: "/home/me\n", exit: 0)
                + cycle(prompt: "$ ", command: "grep x f", output: "no match\n", exit: 2)
                + cycle(prompt: "$ ", command: "true", output: "", exit: 0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))

        XCTAssertEqual(blocks.count, 3)

        XCTAssertEqual(blocks[0].index, 0)
        XCTAssertEqual(blocks[0].commandText, "pwd")
        XCTAssertEqual(text(blocks[0].output), "/home/me\n")
        XCTAssertEqual(blocks[0].exitCode, 0)

        XCTAssertEqual(blocks[1].index, 1)
        XCTAssertEqual(blocks[1].commandText, "grep x f")
        XCTAssertEqual(text(blocks[1].output), "no match\n")
        XCTAssertEqual(blocks[1].exitCode, 2)

        XCTAssertEqual(blocks[2].index, 2)
        XCTAssertEqual(blocks[2].commandText, "true")
        XCTAssertEqual(blocks[2].output, [])
        XCTAssertEqual(blocks[2].exitCode, 0)
    }

    // MARK: 4. Running (incomplete) command — no D yet

    func testRunningCommandIsIncompleteWithPartialOutput() {
        // A→B→C→<partial output>, NO D. finish() flushes it as incomplete.
        var seg = CommandBlockSegmenter()
        let completed = seg.ingest(bytes(a() + "$ " + b() + "tail -f log" + c() + "line 1\nline 2\n"))
        // Nothing has completed yet (no D).
        XCTAssertTrue(completed.isEmpty)

        let flushed = seg.finish()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertFalse(flushed[0].complete)
        XCTAssertNil(flushed[0].exitCode)
        XCTAssertEqual(flushed[0].commandText, "tail -f log")
        // Partial output captured so far (pinned to the two literal lines fed before finish).
        XCTAssertEqual(text(flushed[0].output), "line 1\nline 2\n")
    }

    func testRunningCommandHasNilDuration() {
        var seg = CommandBlockSegmenter()
        seg.ingest(bytes(a() + "$ " + b() + "watch x" + c() + "tick\n"))
        let flushed = seg.finish()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertNil(flushed[0].durationMS)
    }

    // MARK: 5. No-133 stream → zero blocks (the unstructured case)

    func testNoMarksProducesZeroBlocks() {
        // Plain output with a title + a bell but no 133 marks → nothing to segment.
        let stream = "just some output\n\(ESC)]2;a title\(BEL)more\nstuff\n\(BEL)"
        var seg = CommandBlockSegmenter()
        let completed = seg.ingest(bytes(stream))
        XCTAssertTrue(completed.isEmpty)
        // And finish() flushes nothing because no block was ever opened.
        XCTAssertTrue(seg.finish().isEmpty)
    }

    // MARK: 6. Output cap — runaway command can't blow memory

    func testOutputCapTruncates() {
        let cap = 1024
        // 5000 bytes of output, cap at 1024.
        let big = String(repeating: "y", count: 5000)
        let stream = a() + "$ " + b() + "yes" + c() + big + d(130)
        let blocks = CommandBlockSegmenter.segment(bytes(stream), outputCap: cap)

        XCTAssertEqual(blocks.count, 1)
        // Exactly `cap` bytes captured (pinned), the rest dropped.
        XCTAssertEqual(blocks[0].output.count, cap)
        XCTAssertTrue(blocks[0].outputTruncated)
        // The block still CLOSED cleanly on D despite the truncation.
        XCTAssertTrue(blocks[0].complete)
        XCTAssertEqual(blocks[0].exitCode, 130)
        // And the captured prefix is the literal output prefix.
        XCTAssertEqual(text(blocks[0].output), String(repeating: "y", count: cap))
    }

    func testUnderCapNotTruncated() {
        let stream = a() + "$ " + b() + "echo" + c() + String(repeating: "z", count: 100) + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream), outputCap: 1024)
        XCTAssertEqual(blocks[0].output.count, 100)
        XCTAssertFalse(blocks[0].outputTruncated)
    }

    // MARK: 7. Robustness — embedded 133 byte, nested marks, control sequences preserved

    func testEmbeddedRawByteInOutputDoesNotSpoof() {
        // The literal bytes "133;D" appearing in OUTPUT (NOT inside an OSC) must be captured
        // as plain output, not parsed as a finish mark.
        let stream = a() + "$ " + b() + "cat f" + c() + "the marker 133;D appears here\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(text(blocks[0].output), "the marker 133;D appears here\n")
        XCTAssertTrue(blocks[0].complete)
        XCTAssertEqual(blocks[0].exitCode, 0)
    }

    func testSpoofedMarkInsideStringSequenceIsIgnored() {
        // A DCS string body that embeds `ESC]133;D;99 ST` must NOT close the block — the
        // string sequence swallows it (the live sniffer's security property, mirrored).
        let dcsSpoof = "\(ESC)P\(ESC)]133;D;99\(BEL)\(ST)" // DCS … ST, with a fake D inside
        let stream = a() + "$ " + b() + "run" + c() + "real out\n" + dcsSpoof + "more out\n" + d(7)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        // The block closed on the REAL D (exit 7), not the spoofed D;99.
        XCTAssertEqual(blocks[0].exitCode, 7)
        XCTAssertTrue(blocks[0].complete)
    }

    func testControlSequencesPreservedInOutput() {
        // Output with a real CSI color sequence — the raw bytes are preserved verbatim.
        let colored = "\(ESC)[31mRED\(ESC)[0m\n"
        let stream = a() + "$ " + b() + "ls --color" + c() + colored + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(text(blocks[0].output), colored)
        // And the CSI bytes really are present (ESC + '[' + '3' + '1' + 'm').
        XCTAssertTrue(blocks[0].output.contains(0x1B))
    }

    func testCommandWithNoBStillCapturesOutput() {
        // First-prompt case: a C with no preceding B (joined mid-session). The block opens
        // at C with an empty commandText, output captured, closes on D.
        let stream = c() + "orphan output\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, "")
        XCTAssertEqual(text(blocks[0].output), "orphan output\n")
    }

    func testPhantomDWithNoCommandDropped() {
        // The classic first-prompt phantom `D;0` with no open block → emits nothing.
        let stream = a() + "$ " + d(0) + b() + "ls" + c() + "x\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        // Only the real ls block — the phantom D produced no block.
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, "ls")
    }

    func testRepromptWithoutDClosesPriorAsIncomplete() {
        // A new A (prompt) arrives while a block is still open (no D) — the prior block is
        // flushed as incomplete, the new cycle starts fresh.
        let stream =
            a() + "$ " + b() + "hang" + c() + "partial\n"
                + a() + "$ " + b() + "ls" + c() + "ok\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertFalse(blocks[0].complete)
        XCTAssertEqual(blocks[0].commandText, "hang")
        XCTAssertEqual(text(blocks[0].output), "partial\n")
        XCTAssertTrue(blocks[1].complete)
        XCTAssertEqual(blocks[1].commandText, "ls")
    }

    // MARK: 8. Chunk-boundary invariance — split anywhere = same blocks

    func testChunkingInvariance() {
        let stream =
            cycle(prompt: "$ ", command: "echo one", output: "one\n", exit: 0)
                + cycle(prompt: "$ ", command: "echo two", output: "two\n", exit: 0)
        let raw = bytes(stream)
        let whole = CommandBlockSegmenter.segment(raw)

        // Feed one byte at a time (bypasses any batching) — must produce identical blocks.
        var seg = CommandBlockSegmenter()
        var chunked: [CommandBlockSegmenter.CommandBlock] = []
        for byte in raw {
            chunked.append(contentsOf: seg.ingest([byte]))
        }
        chunked.append(contentsOf: seg.finish())
        XCTAssertEqual(whole, chunked)

        // Also split the marks themselves across a boundary (mid-OSC).
        let half = raw.count / 2
        var seg2 = CommandBlockSegmenter()
        var twoChunk = seg2.ingest(Array(raw[0..<half]))
        twoChunk.append(contentsOf: seg2.ingest(Array(raw[half...])))
        twoChunk.append(contentsOf: seg2.finish())
        XCTAssertEqual(whole, twoChunk)
    }

    // MARK: 9. ST-terminated marks (ESC \ instead of BEL)

    func testSTTerminatedMarks() {
        // Use ESC \ as the OSC terminator instead of BEL throughout.
        func aST() -> String { "\(ESC)]133;A\(ST)" }
        func bST() -> String { "\(ESC)]133;B\(ST)" }
        func cST() -> String { "\(ESC)]133;C\(ST)" }
        func dST(_ e: Int) -> String { "\(ESC)]133;D;\(e)\(ST)" }
        let stream = aST() + "$ " + bST() + "make" + cST() + "built\n" + dST(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, "make")
        XCTAssertEqual(text(blocks[0].output), "built\n")
        XCTAssertEqual(blocks[0].exitCode, 0)
    }
}
