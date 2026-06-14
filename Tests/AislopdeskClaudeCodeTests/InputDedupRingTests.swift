import Foundation
import XCTest
@testable import AislopdeskClaudeCode

/// WF-7 dedup ring tests (input-box B1 echo suppression).
final class InputDedupRingTests: XCTestCase {
    private func str(_ bytes: [UInt8]) -> String { String(bytes: bytes, encoding: .utf8) ?? "" }

    // MARK: Exact echo suppressed

    func testExactLineEchoSuppressed() {
        let ring = InputDedupRing()
        ring.recordSent(Array("ls -la\n".utf8))
        // PTY echoes with CR/LF translation.
        let out = ring.filter(Array("ls -la\r\n".utf8))
        XCTAssertTrue(out.isEmpty, "the full echo should be suppressed, got \(str(out))")
        XCTAssertEqual(ring.pendingCount, 0)
    }

    func testExactEchoWithoutNewline() {
        let ring = InputDedupRing()
        ring.recordSent(Array("hello".utf8))
        XCTAssertEqual(ring.filter(Array("hello".utf8)), [])
    }

    // MARK: Non-echo output passes through

    func testNonEchoOutputPassesThrough() {
        let ring = InputDedupRing()
        ring.recordSent(Array("ls\n".utf8))
        let out = ring.filter(Array("total 42\r\n".utf8))
        // None of this matches the expected echo `ls\r\n`, so it all passes through.
        XCTAssertEqual(str(out), "total 42\r\n")
    }

    func testNoPendingPassesEverythingThrough() {
        let ring = InputDedupRing()
        let out = ring.filter(Array("arbitrary output".utf8))
        XCTAssertEqual(str(out), "arbitrary output")
    }

    // MARK: Echo then real output in one chunk

    func testEchoFollowedByRealOutputInSameChunk() {
        let ring = InputDedupRing()
        ring.recordSent(Array("pwd\n".utf8))
        // Echo `pwd\r\n` then the command's real output.
        let out = ring.filter(Array("pwd\r\n/Users/dev\r\n".utf8))
        XCTAssertEqual(str(out), "/Users/dev\r\n")
    }

    // MARK: Partial echo split across chunks

    func testPartialEchoAcrossChunksSuppressed() {
        let ring = InputDedupRing()
        ring.recordSent(Array("git status\n".utf8))
        // Expected echo: "git status\r\n". Arrive split.
        XCTAssertEqual(ring.filter(Array("git ".utf8)), [])
        XCTAssertEqual(ring.filter(Array("sta".utf8)), [])
        XCTAssertEqual(ring.filter(Array("tus\r".utf8)), [])
        let last = ring.filter(Array("\n".utf8))
        XCTAssertEqual(last, [])
        XCTAssertEqual(ring.pendingCount, 0)
    }

    func testPartialEchoThenRealOutputAcrossChunks() {
        let ring = InputDedupRing()
        ring.recordSent(Array("echo hi\n".utf8))
        XCTAssertEqual(ring.filter(Array("echo ".utf8)), [])
        // The rest of the echo plus the real output in one chunk.
        let out = ring.filter(Array("hi\r\nhi\r\n".utf8))
        XCTAssertEqual(str(out), "hi\r\n")
    }

    // MARK: Mid-echo interruption resets cleanly (no permanent desync)

    func testNonEchoByteMidEchoFlushesHeldPrefix() {
        let ring = InputDedupRing()
        ring.recordSent(Array("abc".utf8))
        // Output starts matching ("ab") then diverges ("X"). Hold-and-confirm GUARANTEES
        // the held "ab" prefix is NOT silently eaten: since it was real output (not the
        // echo), it is flushed back intact when "X" breaks the match. Then "abc" matches
        // the full pending echo and IS suppressed. So passthrough is "abX".
        let out = ring.filter(Array("abXabc".utf8))
        XCTAssertEqual(str(out), "abX")
        XCTAssertEqual(ring.pendingCount, 0)
    }

    // MARK: Ring eviction after bound

    func testRingEvictionAfterBound() {
        let ring = InputDedupRing(capacity: 8)
        // Send 12 bytes total; only the last 8 are retained as pending.
        ring.recordSent(Array("ABCD".utf8))
        ring.recordSent(Array("EFGHIJKL".utf8)) // now 12 → evict oldest 4 ("ABCD")
        XCTAssertEqual(ring.pendingCount, 8)
        // The evicted "ABCD" echo now passes through (we no longer expect it); the
        // retained "EFGHIJKL" echo is suppressed.
        let out = ring.filter(Array("ABCDEFGHIJKL".utf8))
        XCTAssertEqual(str(out), "ABCD")
    }

    func testResetClearsPending() {
        let ring = InputDedupRing()
        ring.recordSent(Array("xyz".utf8))
        XCTAssertEqual(ring.pendingCount, 3)
        ring.reset()
        XCTAssertEqual(ring.pendingCount, 0)
        XCTAssertEqual(str(ring.filter(Array("xyz".utf8))), "xyz")
    }

    // MARK: Multiple sends accumulate

    func testMultipleSendsAccumulateAndSuppress() {
        let ring = InputDedupRing()
        ring.recordSent(Array("foo".utf8))
        ring.recordSent(Array("bar".utf8))
        // Combined expected echo "foobar".
        XCTAssertEqual(ring.filter(Array("foobar".utf8)), [])
    }
}
