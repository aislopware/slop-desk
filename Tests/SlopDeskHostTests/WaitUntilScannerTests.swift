import Foundation
import XCTest
@testable import SlopDeskHost

/// The incremental `wait --until` scanner: per-chunk work is bounded (new bytes + a fixed overlap
/// window), yet markers split across chunk boundaries — plain, ANSI-interleaved, or mid-UTF-8 —
/// must match exactly as if the stream had arrived whole.
final class WaitUntilScannerTests: XCTestCase {
    private func makeScanner(
        _ pattern: String,
        cap: Int = AgentControlHandler.waitBufferCap,
    ) throws -> WaitUntilScanner {
        try WaitUntilScanner(regex: NSRegularExpression(pattern: pattern), bufferCap: cap)
    }

    func testMarkerWithinASingleChunkMatches() throws {
        var s = try makeScanner("BUILD COMPLETE")
        XCTAssertFalse(s.ingest(Data("compiling module 1 of 40…\n".utf8)))
        XCTAssertTrue(s.ingest(Data("link ok\nBUILD COMPLETE\n".utf8)))
    }

    func testMarkerSplitAcrossTwoChunksMatches() throws {
        var s = try makeScanner("BUILD COMPLETE")
        XCTAssertFalse(s.ingest(Data("lots of earlier output… BUILD COM".utf8)))
        XCTAssertTrue(s.ingest(Data("PLETE and a tail".utf8)), "the overlap window spans the chunk boundary")
    }

    func testMarkerInterleavedWithAnsiSplitAcrossBoundaryMatches() throws {
        // The SGR escape is split MID-SEQUENCE at the chunk boundary: `ESC [ 3` | `2 m`. The raw
        // carry must hold the partial escape so the reassembled sequence strips cleanly and the
        // marker matches across the boundary.
        var s = try makeScanner("BUILD COMPLETE")
        XCTAssertFalse(s.ingest(Data("BUILD \u{1B}[3".utf8)))
        XCTAssertTrue(s.ingest(Data("2mCOMPLETE\u{1B}[0m\n".utf8)))
    }

    func testOscSplitAcrossBoundaryStripsCleanAndMarkerMatches() throws {
        // An OSC title sequence split before its BEL terminator: its body must never leak into
        // the matched text, and the marker after the terminator must match.
        var s = try makeScanner("^READY>$", cap: AgentControlHandler.waitBufferCap)
        XCTAssertFalse(s.ingest(Data("\u{1B}]0;window ti".utf8)))
        XCTAssertTrue(s.ingest(Data("tle\u{07}READY>".utf8)))
    }

    func testMultibyteUTF8SplitAcrossBoundaryDecodes() throws {
        // `é` (0xC3 0xA9) split across the boundary: the carry must hold the lead byte so the
        // codepoint decodes whole — a per-chunk lossy decode would mangle it to `?` and miss.
        var s = try makeScanner("réussite")
        var first = Data("compilation r".utf8)
        first.append(0xC3)
        XCTAssertFalse(s.ingest(first))
        var second = Data([0xA9])
        second.append(Data("ussite\n".utf8))
        XCTAssertTrue(s.ingest(second))
    }

    func testRunawayUnterminatedOscIsForceFlushedAndScanKeepsWorking() throws {
        // An unterminated string-command body far past the carry budget (hostile bytes / a giant
        // inline-image OSC) must not buffer raw carry without bound — it is force-flushed, and a
        // later plain marker still matches.
        var s = try makeScanner("MARKER")
        var giant = Data("\u{1B}]1337;File=".utf8)
        giant.append(Data(repeating: 0x41, count: 4096))
        XCTAssertFalse(s.ingest(giant))
        XCTAssertTrue(s.ingest(Data("\nMARKER\n".utf8)))
    }

    func testStrippedAccumulatorKeepsCapAndTrimsOldestHalf() throws {
        var s = try makeScanner("NEVER MATCHES ANYTHING", cap: 1024)
        for _ in 0..<64 {
            _ = s.ingest(Data(repeating: UInt8(ascii: "a"), count: 64)) // 4 KiB of plain output
        }
        XCTAssertLessThanOrEqual(s.stripped.count, 1024, "the stripped accumulator honours the cap")
        XCTAssertGreaterThan(s.stripped.count, 0, "trim keeps the newest half, not nothing")
    }

    func testLoneTrailingEscapeIsCarriedNotEmitted() throws {
        // A chunk ending in a bare ESC is undecidable (CSI? OSC? two-byte?) — held back, then
        // resolved by the next chunk.
        var s = try makeScanner("done")
        XCTAssertFalse(s.ingest(Data([0x64, 0x6F, 0x1B]))) // "do" + ESC
        XCTAssertTrue(s.ingest(Data("[32mne\u{1B}[0m".utf8)), "ESC + [32m reassembles and strips; 'done' matches")
    }
}
