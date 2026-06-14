import Foundation
import XCTest
@testable import AislopdeskClaudeCode

/// R17 DEDUP-1 regression: when the ring evicts FIFO to stay under capacity, any bytes in the evicted
/// region that were already HELD (tentatively suppressed during an in-flight match) must be FLUSHED,
/// not silently eaten — otherwise the user's echoed input vanishes from the terminal (visible
/// corruption). The held bytes are real output; eviction is a non-confirmation of the match.
final class InputDedupRingEvictionTests: XCTestCase {
    /// The exact corruption scenario: a held echo prefix is evicted by a later send, then the rest of
    /// the echo arrives. The held prefix must survive (flushed), so the full echo renders intact.
    func testEvictionDuringHeldMatchFlushesHeldBytesNotEaten() {
        let ring = InputDedupRing(capacity: 16)
        ring.recordSent(Data("echo hello\n".utf8)) // expected echo "echo hello\r\n" (12 bytes)
        let out1 = ring.filter(Data("echo hel".utf8)) // matches 8, held → emits nothing yet
        XCTAssertEqual(Array(out1), [], "the partial echo prefix is held, awaiting confirmation")

        // A second large send overflows the 16-byte ring and evicts the held prefix.
        ring.recordSent(Data("second line here\n".utf8))
        let out2 = ring.filter(Data("lo\r\n".utf8))

        let rendered = String(bytes: out1 + out2, encoding: .utf8)
        XCTAssertEqual(
            rendered, "echo hello\r\n",
            "the held 'echo hel' evicted unconfirmed must be FLUSHED (no byte loss / terminal corruption)",
        )
    }

    // MARK: positive controls — dedup is otherwise unchanged

    func testExactEchoStillFullySuppressedWhenNoEviction() {
        let ring = InputDedupRing(capacity: 4096)
        ring.recordSent(Data("ls\n".utf8))
        let out = ring.filter(Data("ls\r\n".utf8)) // exact echo
        XCTAssertEqual(Array(out), [], "an exact echo with no eviction is fully suppressed (dedup intact)")
    }

    func testPartialEchoAcrossChunksStillSuppressedWhenNoEviction() {
        let ring = InputDedupRing(capacity: 4096)
        ring.recordSent(Data("ls -la\n".utf8))
        let a = ring.filter(Data("ls -".utf8)) // held
        let b = ring.filter(Data("la\r\n".utf8)) // completes echo → confirmed, suppressed
        XCTAssertEqual(Array(a) + Array(b), [], "partial echo across chunks fully suppressed (no eviction)")
    }

    func testNonEchoOutputPassesThrough() {
        let ring = InputDedupRing(capacity: 4096)
        ring.recordSent(Data("ls\n".utf8))
        let out = ring.filter(Data("total 8\r\n".utf8)) // not the echo
        XCTAssertEqual(String(bytes: out, encoding: .utf8), "total 8\r\n", "non-echo output is untouched")
    }

    func testResetClearsFlushBuffer() {
        let ring = InputDedupRing(capacity: 16)
        ring.recordSent(Data("echo hello\n".utf8))
        _ = ring.filter(Data("echo hel".utf8)) // held 8
        ring.recordSent(Data("second line here\n".utf8)) // evicts → flushBuffer has "echo hel"
        ring.reset() // hard clear
        let out = ring.filter(Data("xyz".utf8))
        XCTAssertEqual(
            String(bytes: out, encoding: .utf8),
            "xyz",
            "reset clears the flush buffer; subsequent output is untouched",
        )
    }
}
