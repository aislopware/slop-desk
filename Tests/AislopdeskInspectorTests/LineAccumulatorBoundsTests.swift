import Foundation
import XCTest
@testable import AislopdeskInspector

/// R17 INSP-PARSE-1/2/3 regression: the transcript line splitter must (1) BOUND the buffered partial
/// line so an unterminated/runaway line can't OOM the host, (2) drain newline-dense input in LINEAR
/// time (the old front-removal was O(n²) — a 1 MB all-newlines poll blocked the tailer actor ~10s),
/// and (3) surface an invalid-UTF8 line LOSSILY rather than silently dropping it.
final class LineAccumulatorBoundsTests: XCTestCase {
    // MARK: existing behavior preserved

    func testSplitAcrossWritesEmitsOnce() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.append(Data("abc".utf8)), [])
        XCTAssertEqual(acc.append(Data("def\n".utf8)), ["abcdef"])
    }

    func testMultipleLinesAndCRLF() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.append(Data("one\r\ntwo\nthree\n".utf8)), ["one", "two", "three"])
        XCTAssertEqual(acc.bufferedByteCount, 0)
    }

    func testTrailingPartialHeld() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.append(Data("complete\npartial".utf8)), ["complete"])
        XCTAssertEqual(acc.bufferedByteCount, Data("partial".utf8).count)
    }

    // MARK: INSP-PARSE-1 — unbounded pending is capped

    func testOverlongLineIsBoundedNotUnbounded() {
        var acc = LineAccumulator(maxPendingBytes: 1024)
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 4096)
        for _ in 0..<25 { _ = acc.append(chunk) } // 100 KB, NO newline
        XCTAssertLessThanOrEqual(
            acc.bufferedByteCount,
            1024,
            "an unterminated line must be bounded by the cap, not grow toward OOM",
        )
    }

    func testOverlongLineSkipsUntilNewlineThenResyncs() {
        var acc = LineAccumulator(maxPendingBytes: 1024)
        _ = acc.append(Data(repeating: UInt8(ascii: "x"), count: 5000)) // the over-long line
        XCTAssertLessThanOrEqual(acc.bufferedByteCount, 1024)
        // A newline ENDS the over-long line (emit nothing for it); the following line resyncs cleanly.
        let lines = acc.append(Data("\nclean\n".utf8))
        XCTAssertEqual(lines, ["clean"], "over-long line discarded; the next line is clean")
        XCTAssertEqual(acc.bufferedByteCount, 0)
    }

    // MARK: INSP-PARSE-2 — linear drain

    func testNewlineDenseDrainIsLinearAndFast() {
        var acc = LineAccumulator()
        let n = 200_000
        let data = Data(repeating: UInt8(ascii: "\n"), count: n) // n empty lines
        let start = Date()
        let lines = acc.append(data)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(lines.count, n, "every newline yields one (empty) line")
        XCTAssertLessThan(
            elapsed,
            2.0,
            "linear drain: \(n) newlines must not be O(n²) (the old front-removal was ~seconds)",
        )
    }

    // MARK: INSP-PARSE-3 — invalid UTF-8 surfaces lossily

    func testInvalidUTF8LineSurfacesLossilyNotDropped() {
        var acc = LineAccumulator()
        var line = Data("good".utf8)
        line.append(0x80) // a lone continuation byte — invalid UTF-8
        line.append(Data("\n".utf8))
        let lines = acc.append(line)
        XCTAssertEqual(lines.count, 1, "an invalid-UTF8 line must still emit (lossy U+FFFD), not be dropped")
        XCTAssertTrue(lines[0].hasPrefix("good"), "the valid prefix is preserved")
    }
}
