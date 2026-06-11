import XCTest
import Foundation
import AislopdeskProtocol
@testable import AislopdeskHost

/// WF-3 host-side title/bell sniffer tests. The sniffer observes the SAME outbound byte
/// stream the host relays and emits `.title` (OSC 0/2) / `.bell` (standalone BEL) CONTROL
/// messages — making wire types 21/22 actually fire end to end.
///
/// The two crown-jewel properties:
///   1. **Non-destructive** — feeding the stream and concatenating the chunks back yields
///      the original bytes UNCHANGED (the sniffer never consumes/strips a byte). Asserted
///      in `assertForwardsUnchanged` on every test stream below.
///   2. **Split-boundary equivalence** — feeding the SAME stream chunked at every boundary
///      (one byte at a time .. whole) produces identical control messages.
final class HostTitleBellSnifferTests: XCTestCase {

    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"
    private let ST = "\u{1B}\\" // ESC \

    // MARK: Helpers

    /// Feeds `bytes` to a fresh sniffer in one shot; returns all emitted control messages.
    private func observeWhole(_ bytes: [UInt8]) -> [WireMessage] {
        HostTitleBellSniffer().observe(bytes)
    }

    /// Feeds `bytes` to a fresh sniffer split into chunks of `size`; returns all messages.
    private func observeChunked(_ bytes: [UInt8], size: Int) -> [WireMessage] {
        let s = HostTitleBellSniffer()
        var out: [WireMessage] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + size, bytes.count)
            out.append(contentsOf: s.observe(Array(bytes[i..<end])))
            i = end
        }
        return out
    }

    /// Asserts the NON-DESTRUCTIVE invariant for `bytes`: an out-of-band relay that
    /// forwards each chunk's original bytes (the contract of the `onChunk` sink, which
    /// yields the UNCHANGED chunk regardless of what the sniffer detected) reconstructs the
    /// input byte-for-byte, at every chunk boundary. The sniffer only OBSERVES; it must
    /// never alter the relayed bytes. We model the relay explicitly: the sniffer's
    /// `observe` return value is discarded into the control side, while the raw chunk is
    /// appended to the forwarded buffer.
    private func assertForwardsUnchanged(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        for size in 1...max(1, bytes.count) {
            let s = HostTitleBellSniffer()
            var forwarded: [UInt8] = []
            var i = 0
            while i < bytes.count {
                let end = min(i + size, bytes.count)
                let chunk = Array(bytes[i..<end])
                _ = s.observe(chunk)          // sniff (control side) — return discarded.
                forwarded.append(contentsOf: chunk) // relay (data side) — UNCHANGED bytes.
                i = end
            }
            XCTAssertEqual(forwarded, bytes, "relay altered bytes at chunk size \(size)", file: file, line: line)
        }
    }

    // MARK: OSC 0 + BEL terminator → .title

    func testOSC0WithBELTerminatorEmitsTitle() {
        let bytes = Array("\(ESC)]0;hello\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("hello")])
        assertForwardsUnchanged(bytes)
    }

    // MARK: OSC 2 + ST terminator → .title

    func testOSC2WithSTTerminatorEmitsTitle() {
        let bytes = Array("\(ESC)]2;my window\(ST)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("my window")])
        assertForwardsUnchanged(bytes)
    }

    func testOSC0WithSTTerminatorEmitsTitle() {
        let bytes = Array("\(ESC)]0;both\(ST)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("both")])
        assertForwardsUnchanged(bytes)
    }

    func testOSC2WithBELTerminatorEmitsTitle() {
        let bytes = Array("\(ESC)]2;winbel\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("winbel")])
        assertForwardsUnchanged(bytes)
    }

    // MARK: OSC split across two chunks → still exactly one .title

    func testOSCSplitAcrossTwoChunks() {
        let bytes = Array("\(ESC)]0;split title\(BEL)".utf8)
        // Split at every interior boundary: each split must still yield exactly one title.
        for cut in 1..<bytes.count {
            let s = HostTitleBellSniffer()
            var out = s.observe(Array(bytes[0..<cut]))
            out.append(contentsOf: s.observe(Array(bytes[cut..<bytes.count])))
            XCTAssertEqual(out, [.title("split title")], "split at \(cut) diverged")
        }
        assertForwardsUnchanged(bytes)
    }

    func testOSCSplitEveryChunkSizeEquivalence() {
        let bytes = Array("\(ESC)]2;Claude Code — repo\(BEL)".utf8)
        let expected: [WireMessage] = [.title("Claude Code — repo")]
        for size in 1...bytes.count {
            XCTAssertEqual(observeChunked(bytes, size: size), expected, "chunk size \(size)")
        }
        assertForwardsUnchanged(bytes)
    }

    // MARK: real standalone BEL → .bell

    func testStandaloneBELEmitsBell() {
        let bytes = Array("\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.bell])
        assertForwardsUnchanged(bytes)
    }

    func testBELAmidContentEmitsBell() {
        let bytes = Array("abc\(BEL)def".utf8)
        XCTAssertEqual(observeWhole(bytes), [.bell])
        assertForwardsUnchanged(bytes)
    }

    func testMultipleStandaloneBELsEmitMultipleBells() {
        let bytes = Array("\(BEL)\(BEL)\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.bell, .bell, .bell])
        assertForwardsUnchanged(bytes)
    }

    // MARK: BEL that terminates an OSC → exactly one .title, NO .bell (disambiguation)

    func testBELTerminatingOSCIsNotABell() {
        let bytes = Array("\(ESC)]0;title via bel\(BEL)".utf8)
        let msgs = observeWhole(bytes)
        XCTAssertEqual(msgs, [.title("title via bel")])
        // Explicitly: NO .bell was emitted even though a BEL byte was present.
        XCTAssertFalse(msgs.contains(.bell), "OSC-terminating BEL must not fire .bell")
        assertForwardsUnchanged(bytes)
    }

    func testTitleThenRealBellAreDistinguished() {
        // OSC 0 ended by BEL (title only), then a standalone BEL (a real bell).
        let bytes = Array("\(ESC)]0;t\(BEL)\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("t"), .bell])
        assertForwardsUnchanged(bytes)
    }

    // MARK: stray ESC followed by a valid sequence — introducer not swallowed

    func testUnterminatedOSCThenValidTitleNotLost() {
        // `ESC ]0;abc` (no explicit terminator) directly followed by `ESC ]2;real BEL`.
        // The stray ESC ends the first OSC — and because `0;abc` is itself a COMPLETE
        // OSC 0 payload, ending it fires `.title("abc")` — AND that same ESC introduces
        // the next OSC. The headline property: the second title `"real"` must NOT be
        // dropped (the prior stray-ESC bug swallowed the next sequence's introducer).
        let bytes = Array("\(ESC)]0;abc".utf8) + Array("\(ESC)]2;real\(BEL)".utf8)
        let msgs = observeWhole(bytes)
        XCTAssertEqual(msgs, [.title("abc"), .title("real")])
        // Explicit: the introducer of the SECOND sequence was not swallowed.
        XCTAssertTrue(msgs.contains(.title("real")), "second title lost — introducer swallowed")
        assertForwardsUnchanged(bytes)
    }

    func testUnterminatedOSCThenValidTitleSplitConsistent() {
        let bytes = Array("\(ESC)]0;abc".utf8) + Array("\(ESC)]2;real\(BEL)".utf8)
        let expected: [WireMessage] = [.title("abc"), .title("real")]
        for size in 1...bytes.count {
            XCTAssertEqual(observeChunked(bytes, size: size), expected, "chunk size \(size)")
        }
    }

    func testStrayESCInOSCThenBELIsNotABell() {
        // `ESC ]0;abc` (a complete OSC 0 payload) then `ESC X`. The first `ESC` after the OSC ends it, so
        // the title `abc` fires — but `ESC X` is the SOS (Start Of String) introducer, a STRING sequence
        // whose body a conformant terminal swallows to its ST/BEL terminator, emitting NOTHING. So the
        // trailing BEL is the SOS TERMINATOR, NOT a real bell — exactly what this test's NAME asserts.
        // (R9 #4: before the DCS/SOS/PM/APC string-state fix, the sniffer wrongly fired a phantom `.bell`
        // here, since it treated `X` as an untracked escape and re-parsed the BEL in ground state.)
        let bytes = Array("\(ESC)]0;abc".utf8) + Array("\(ESC)X".utf8) + Array(BEL.utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("abc")])
        assertForwardsUnchanged(bytes)
    }

    /// R9 #4 (security): a BEL inside a DCS/SOS/PM/APC string sequence is the string body/terminator, not
    /// a real bell — a conformant terminal never rings it. A malicious remote program (`printf
    /// '\033P\007'`) must not be able to inject a phantom bell, and an `ESC]2;…` embedded in a string body
    /// must not spoof the tab title.
    func testStringSequencesSwallowEmbeddedBellAndTitle() {
        // DCS with an embedded BEL → swallowed (no phantom bell). `ESC P` … `BEL`.
        XCTAssertEqual(observeWhole(Array("\(ESC)Pq\(BEL)".utf8)), [], "a BEL inside a DCS string is not a bell")
        // APC with an embedded OSC-2-looking title → swallowed (no title spoof). `ESC _` … `ESC \`.
        let apcSpoof = Array("\(ESC)_\(ESC)]2;pwned\(BEL)".utf8) + Array("\(ESC)\\".utf8)
        XCTAssertEqual(observeWhole(apcSpoof), [], "an OSC embedded in an APC string body must not spoof the title")
        // A REAL OSC 2 after a swallowed PM string still fires (resync is clean).
        let pmThenReal = Array("\(ESC)^junk\(BEL)".utf8) + Array("\(ESC)]2;real\(BEL)".utf8)
        XCTAssertEqual(observeWhole(pmThenReal), [.title("real")], "a real title after a swallowed PM string still fires")
    }

    func testDoubleESCThenBackslashTerminatesST() {
        // `ESC ]2;x` then `ESC ESC \`. First ESC → oscEscape; second ESC (not `\`) ends the
        // OSC (firing the title) and re-enters escape; the `\` is then a lone nF escape
        // final consumed cleanly. The title fires once; no bell.
        let bytes = Array("\(ESC)]2;x".utf8) + Array("\(ESC)\(ESC)\\".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("x")])
        assertForwardsUnchanged(bytes)
    }

    // MARK: over-long unterminated OSC is bounded and the parser resyncs

    func testOverlongUnterminatedOSCBoundedThenResync() {
        // A huge unterminated OSC (far exceeds the 4096 cap) followed by a real title. The
        // overlong OSC must be abandoned at the cap (no partial title, no wedge) and the
        // following valid OSC 0 must still be detected.
        let junk = String(repeating: "x", count: 10_000)
        let bytes = Array("\(ESC)]2;\(junk)".utf8) + Array("\(ESC)]0;after\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("after")])
        assertForwardsUnchanged(bytes)
    }

    func testOverlongOSCBoundedSplitConsistent() {
        let junk = String(repeating: "y", count: 9000)
        let bytes = Array("\(ESC)]0;\(junk)".utf8) + Array("\(ESC)]2;done\(BEL)".utf8)
        let expected: [WireMessage] = [.title("done")]
        // A handful of representative chunk sizes (full 1..count is O(n^2) over 9k bytes).
        for size in [1, 2, 7, 64, 128, 4096, bytes.count] {
            XCTAssertEqual(observeChunked(bytes, size: size), expected, "chunk size \(size)")
        }
    }

    /// REGRESSION: an over-cap OSC whose OWN terminator is a `BEL` must have that BEL consumed
    /// as the (discarded) OSC's terminator — NOT re-parsed in ground as a phantom `.bell`. The
    /// old code dropped to `.ground` AT the cap, so the terminator BEL fired a spurious bell
    /// (and could misread following bytes). A following real title must still be detected.
    func testOverlongOSCTerminatorBELIsNotAPhantomBell() {
        let junk = String(repeating: "x", count: 5000)          // > 4096 cap
        let bytes = Array("\(ESC)]2;\(junk)\(BEL)".utf8)         // over-cap OSC TERMINATED by BEL
            + Array("\(ESC)]0;real\(BEL)".utf8)                  // then a valid title
        let msgs = observeWhole(bytes)
        XCTAssertFalse(msgs.contains(.bell), "an over-cap OSC's terminator BEL must not fire a phantom .bell")
        XCTAssertEqual(msgs, [.title("real")], "no phantom bell; the following title is still detected")
        assertForwardsUnchanged(bytes)
        for size in [1, 3, 64, 4096, bytes.count] {
            XCTAssertEqual(observeChunked(bytes, size: size), [.title("real")], "chunk size \(size)")
        }
    }

    /// REGRESSION sibling: an over-cap OSC terminated by `ST` (`ESC \`) resyncs cleanly with no
    /// phantom title/bell, and a following real title is detected.
    func testOverlongOSCTerminatedBySTResyncs() {
        let junk = String(repeating: "x", count: 5000)
        let bytes = Array("\(ESC)]2;\(junk)\(ST)".utf8) + Array("\(ESC)]0;real\(BEL)".utf8)
        let msgs = observeWhole(bytes)
        XCTAssertFalse(msgs.contains(.bell))
        XCTAssertEqual(msgs, [.title("real")])
        assertForwardsUnchanged(bytes)
    }

    // MARK: OSC 1 (icon name only) is ignored; other OSC ignored

    func testOSC1IconNameIgnored() {
        // OSC 1 sets the icon name ONLY, never the window title — we do not surface it.
        let bytes = Array("\(ESC)]1;iconname\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [])
        assertForwardsUnchanged(bytes)
    }

    func testUnrelatedOSCIgnored() {
        // OSC 8 (hyperlink), OSC 52 (clipboard), OSC 133 (prompt mark), OSC 4 (palette).
        let bytes =
            Array("\(ESC)]8;;https://example.com\(BEL)".utf8)
            + Array("\(ESC)]52;c;BASE64==\(BEL)".utf8)
            + Array("\(ESC)]133;A\(BEL)".utf8)
            + Array("\(ESC)]4;1;rgb:00/00/00\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [])
        assertForwardsUnchanged(bytes)
    }

    func testOSCWithoutSemicolonIgnored() {
        // A bare `ESC]0 BEL` with no `;` is malformed (no title text); emit nothing.
        let bytes = Array("\(ESC)]0\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [])
        assertForwardsUnchanged(bytes)
    }

    func testEmptyTitleIsEmittedOnce() {
        // `ESC]0; BEL` — an explicitly empty title (clears the title). Valid; emit "".
        let bytes = Array("\(ESC)]2;\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("")])
        assertForwardsUnchanged(bytes)
    }

    func testTitleWithSemicolonsInText() {
        // Only the FIRST ';' separates Ps from Pt; the title text keeps its semicolons.
        let bytes = Array("\(ESC)]0;a;b;c\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("a;b;c")])
        assertForwardsUnchanged(bytes)
    }

    // MARK: title dedup (trivial coalescing)

    func testIdenticalConsecutiveTitlesDeduped() {
        let bytes =
            Array("\(ESC)]0;same\(BEL)".utf8)
            + Array("\(ESC)]2;same\(BEL)".utf8)   // same text via a different Ps — deduped
            + Array("\(ESC)]0;same\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("same")])
    }

    func testDifferentTitlesNotDeduped() {
        let bytes =
            Array("\(ESC)]0;one\(BEL)".utf8)
            + Array("\(ESC)]2;two\(BEL)".utf8)
            + Array("\(ESC)]0;one\(BEL)".utf8)   // back to "one" — different from prev, emit
        XCTAssertEqual(observeWhole(bytes), [.title("one"), .title("two"), .title("one")])
    }

    // MARK: realistic interleaved stream — title, bells, content, unrelated escapes

    func testInterleavedRealWorldStream() {
        let stream =
            "welcome\n"
            + "\(ESC)]0;Claude Code\(BEL)"            // OSC 0 title (BEL)
            + "$ ls\n"
            + "\(ESC)[?1049h"                          // alt-screen enter (CSI — ignored)
            + "drawing\(ESC)[2J"                        // content + unknown CSI
            + "\(ESC)]2;vim — file.txt\(ST)"           // OSC 2 title (ST)
            + "\(BEL)"                                  // a real bell
            + "\(ESC)[?1049l"                          // alt-screen exit (CSI — ignored)
            + "\(ESC)]2;vim — file.txt\(ST)"           // SAME title again — deduped
            + "bye\n"
        let bytes = Array(stream.utf8)
        let expected: [WireMessage] = [
            .title("Claude Code"),
            .title("vim — file.txt"),
            .bell,
        ]
        XCTAssertEqual(observeWhole(bytes), expected)
        // Split-boundary equivalence across every chunk size.
        for size in 1...bytes.count {
            XCTAssertEqual(observeChunked(bytes, size: size), expected, "chunk size \(size)")
        }
        assertForwardsUnchanged(bytes)
    }

    // MARK: high-bit / UTF-8 content passes through; title is UTF-8 decoded

    func testUTF8TitleAndContentPassThrough() {
        var bytes = Array("café 🚀\n".utf8)
        bytes.append(contentsOf: [0xFF, 0x80, 0xC0])              // raw high-bit content
        bytes.append(contentsOf: Array("\(ESC)]0;日本語\(BEL)".utf8)) // UTF-8 title
        XCTAssertEqual(observeWhole(bytes), [.title("日本語")])
        assertForwardsUnchanged(bytes)
    }

    // MARK: partial sequence at end of chunk never misfires

    func testPartialSequenceAtEndNeverMisfires() {
        let s = HostTitleBellSniffer()
        // Feed a partial OSC; no title yet.
        XCTAssertEqual(s.observe(Array("\(ESC)]0;par".utf8)), [])
        // Complete it next chunk.
        XCTAssertEqual(s.observe(Array("tial\(BEL)".utf8)), [.title("partial")])
    }
}
