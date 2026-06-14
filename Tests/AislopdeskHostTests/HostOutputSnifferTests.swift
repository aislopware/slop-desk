import AislopdeskProtocol
import Foundation
import XCTest
@testable import AislopdeskHost

/// The FUSED ``HostOutputSniffer`` test suite: every test from the two suites it replaces
/// (`HostTitleBellSnifferTests` — 30 tests — and `HostCommandStatusSnifferTests` — 13
/// tests), ported mechanically onto the fused machine, plus the PERMANENT
/// chunking-invariance property test (`testChunkingInvarianceOracle`).
///
/// The crown-jewel properties carried over verbatim:
///   1. **Non-destructive** — feeding the stream and concatenating the chunks back yields
///      the original bytes UNCHANGED (the sniffer never consumes/strips a byte). Asserted
///      in `assertForwardsUnchanged` on every title-side test stream below.
///   2. **Split-boundary equivalence** — feeding the SAME stream chunked at every boundary
///      (one byte at a time .. whole) produces identical control messages. The standing
///      oracle below additionally pins the fused fast path to the per-byte path forever
///      (chunk-size-1 bypasses the memchr fast path entirely).
final class HostOutputSnifferTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"
    private let ST = "\u{1B}\\" // ESC \

    // MARK: Helpers

    // A test clock the sniffer reads on each `C`/`D`. `advance(_:)` moves it forward so a
    // `C … D` pair has a known duration, no wall-clock sleep.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        func date() -> Date { lock.lock()
            defer { lock.unlock() }
            return now
        }

        func advance(_ seconds: TimeInterval) { lock.lock()
            now = now.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// OSC 133 ; <mark> BEL.
    private func osc133(_ mark: String) -> [UInt8] { bytes("\u{1B}]133;\(mark)\u{07}") }

    /// The `.commandStatus` subsequence (the fused sniffer may interleave titles/bells).
    private func commandOnly(_ messages: [WireMessage]) -> [WireMessage] {
        messages.filter {
            if case .commandStatus = $0 { return true }
            return false
        }
    }

    /// Feeds `bytes` to a fresh sniffer in one shot; returns all emitted control messages.
    private func observeWhole(_ bytes: [UInt8]) -> [WireMessage] {
        HostOutputSniffer().observe(bytes)
    }

    /// Feeds `bytes` to a fresh sniffer split into chunks of `size`; returns all messages.
    private func observeChunked(_ bytes: [UInt8], size: Int) -> [WireMessage] {
        let s = HostOutputSniffer()
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
    /// never alter the relayed bytes.
    private func assertForwardsUnchanged(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        for size in 1...max(1, bytes.count) {
            let s = HostOutputSniffer()
            var forwarded: [UInt8] = []
            var i = 0
            while i < bytes.count {
                let end = min(i + size, bytes.count)
                let chunk = Array(bytes[i..<end])
                _ = s.observe(chunk) // sniff (control side) — return discarded.
                forwarded.append(contentsOf: chunk) // relay (data side) — UNCHANGED bytes.
                i = end
            }
            XCTAssertEqual(forwarded, bytes, "relay altered bytes at chunk size \(size)", file: file, line: line)
        }
    }

    // MARK: PERMANENT chunking-invariance oracle (fast path vs per-byte path)

    /// STANDING ORACLE — keep forever. `observe(whole)` must equal the concatenation of
    /// `observe` one byte at a time on the SAME machine state trajectory. Chunk-size-1
    /// BYPASSES the memchr fast path (every chunk is a single byte, so the fast path can
    /// never skip ahead), so this property permanently pins the fast path (which only
    /// chooses WHICH bytes reach `step()`) to the per-byte transition table.
    func testChunkingInvarianceOracle() {
        let streams: [String] = [
            // ground content + bells around escapes
            "plain text, no sequences at all",
            "\(BEL)a\(BEL)\(BEL)b",
            // titles, both terminators, dedup, semicolons, empty
            "\(ESC)]0;one\(BEL)\(ESC)]2;one\(BEL)\(ESC)]0;two\(ST)\(ESC)]2;\(BEL)\(ESC)]0;a;b;c\(BEL)",
            // 133 marks: phantom D, A/B, C→D, ST-terminated
            "\(ESC)]133;D;0\(BEL)\(ESC)]133;A\(BEL)\(ESC)]133;C\(BEL)out\(ESC)]133;D;1\(ST)",
            // string sequences swallowing spoofs, then real sequences
            "\(ESC)P\(ESC)]2;spoof\(BEL)\(ESC)X9\(BEL)\(ESC)_\(ESC)]133;C\(BEL)\(ESC)]2;real\(BEL)\(ESC)]133;C\(BEL)",
            // stray ESC ends an OSC + introduces the next; ESC ESC; discard path (over-cap)
            "\(ESC)]0;abc\(ESC)]2;next\(BEL)\(ESC)\(ESC)]0;dbl\(BEL)",
            "\(ESC)]2;" + String(repeating: "x", count: 5000) + "\(BEL)\(BEL)\(ESC)]0;after\(BEL)",
            "\(ESC)]133;" + String(repeating: "y", count: 700) + "\(ST)\(ESC)]133;C\(BEL)",
            // partial sequence left hanging at the end (state carries past the last chunk)
            "tail\(ESC)]0;par",
        ]
        for stream in streams {
            let raw = bytes(stream)
            // Whole vs one-byte-at-a-time — separate machines, same clock semantics (no
            // clock advance mid-stream, so durations match trivially).
            let whole = HostOutputSniffer().observe(raw)
            let perByte = HostOutputSniffer()
            var concatenated: [WireMessage] = []
            for b in raw { concatenated += perByte.observe([b]) }
            XCTAssertEqual(whole, concatenated, "fast path diverged from per-byte on: \(stream.debugDescription)")
            // And a few intermediate chunk sizes for good measure.
            for size in [2, 3, 7, 64] {
                XCTAssertEqual(
                    observeChunked(raw, size: size),
                    whole,
                    "chunk size \(size) diverged on: \(stream.debugDescription)",
                )
            }
        }
    }

    // ============================================================================
    // MARK: - Ported from HostTitleBellSnifferTests (30 tests)

    // ============================================================================

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
            let s = HostOutputSniffer()
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
        XCTAssertEqual(
            observeWhole(pmThenReal),
            [.title("real")],
            "a real title after a swallowed PM string still fires",
        )
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
        let junk = String(repeating: "x", count: 10000)
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
        let junk = String(repeating: "x", count: 5000) // > 4096 cap
        let bytes = Array("\(ESC)]2;\(junk)\(BEL)".utf8) // over-cap OSC TERMINATED by BEL
            + Array("\(ESC)]0;real\(BEL)".utf8) // then a valid title
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
        // OSC 8 (hyperlink), OSC 52 (clipboard), OSC 133;A (prompt mark — recognized by the
        // fused grammar but A is deliberately NOT surfaced), OSC 4 (palette).
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
        // `ESC]2; BEL` — an explicitly empty title (clears the title). Valid; emit "".
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
                + Array("\(ESC)]2;same\(BEL)".utf8) // same text via a different Ps — deduped
                + Array("\(ESC)]0;same\(BEL)".utf8)
        XCTAssertEqual(observeWhole(bytes), [.title("same")])
    }

    func testDifferentTitlesNotDeduped() {
        let bytes =
            Array("\(ESC)]0;one\(BEL)".utf8)
                + Array("\(ESC)]2;two\(BEL)".utf8)
                + Array("\(ESC)]0;one\(BEL)".utf8) // back to "one" — different from prev, emit
        XCTAssertEqual(observeWhole(bytes), [.title("one"), .title("two"), .title("one")])
    }

    // MARK: realistic interleaved stream — title, bells, content, unrelated escapes

    func testInterleavedRealWorldStream() {
        let stream =
            "welcome\n"
                + "\(ESC)]0;Claude Code\(BEL)" // OSC 0 title (BEL)
                + "$ ls\n"
                + "\(ESC)[?1049h" // alt-screen enter (CSI — ignored)
                + "drawing\(ESC)[2J" // content + unknown CSI
                + "\(ESC)]2;vim — file.txt\(ST)" // OSC 2 title (ST)
                + "\(BEL)" // a real bell
                + "\(ESC)[?1049l" // alt-screen exit (CSI — ignored)
                + "\(ESC)]2;vim — file.txt\(ST)" // SAME title again — deduped
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
        bytes.append(contentsOf: [0xFF, 0x80, 0xC0]) // raw high-bit content
        bytes.append(contentsOf: Array("\(ESC)]0;日本語\(BEL)".utf8)) // UTF-8 title
        XCTAssertEqual(observeWhole(bytes), [.title("日本語")])
        assertForwardsUnchanged(bytes)
    }

    // MARK: partial sequence at end of chunk never misfires

    func testPartialSequenceAtEndNeverMisfires() {
        let s = HostOutputSniffer()
        // Feed a partial OSC; no title yet.
        XCTAssertEqual(s.observe(Array("\(ESC)]0;par".utf8)), [])
        // Complete it next chunk.
        XCTAssertEqual(s.observe(Array("tial\(BEL)".utf8)), [.title("partial")])
    }

    // ============================================================================
    // MARK: - Ported from HostCommandStatusSnifferTests (13 tests)

    // ============================================================================

    // MARK: C → D: running then idle with measured duration + exit code

    func testCStartedThenDFinishedWithExitAndDuration() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)

        // C: command started → .running.
        let onC = sniffer.observe(osc133("C"))
        XCTAssertEqual(onC, [.commandStatus(.running)])

        // 12 seconds elapse on the host clock between C and D.
        clock.advance(12)

        // D;0: command finished, exit 0 → .idle with the measured 12_000 ms.
        let onD = sniffer.observe(osc133("D;0"))
        XCTAssertEqual(onD, [.commandStatus(.idle(exitCode: 0, durationMS: 12000))])
    }

    func testQuickCommandSubSecondDuration() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)])
        clock.advance(0.3) // 300 ms
        XCTAssertEqual(
            sniffer.observe(osc133("D;0")),
            [.commandStatus(.idle(exitCode: 0, durationMS: 300))],
        )
    }

    func testNonZeroExitCodeParsed() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        _ = sniffer.observe(osc133("C"))
        clock.advance(1)
        XCTAssertEqual(
            sniffer.observe(osc133("D;130")),
            [.commandStatus(.idle(exitCode: 130, durationMS: 1000))],
        )
    }

    func testDWithoutExitCodeYieldsNilExit() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        _ = sniffer.observe(osc133("C"))
        clock.advance(2)
        // Bare `D` (no exit field) → nil exit, 2_000 ms.
        XCTAssertEqual(
            sniffer.observe(osc133("D")),
            [.commandStatus(.idle(exitCode: nil, durationMS: 2000))],
        )
    }

    func testDExtraKeyValueFieldsTolerated() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        _ = sniffer.observe(osc133("C"))
        clock.advance(1)
        // iTerm2/FinalTerm sometimes append `;aid=...` etc. — the exit (field 2) still parses.
        XCTAssertEqual(
            sniffer.observe(osc133("D;0;aid=123")),
            [.commandStatus(.idle(exitCode: 0, durationMS: 1000))],
        )
    }

    // MARK: D without a matching C is ignored (the first-prompt phantom)

    func testDWithoutPrecedingCIsIgnored() {
        let sniffer = HostOutputSniffer(clock: { Date() })
        // The very first precmd emits D;0 for a command that never started — must be a no-op.
        XCTAssertEqual(sniffer.observe(osc133("D;0")), [])
    }

    func testAandBmarksAreNotSurfaced() {
        let sniffer = HostOutputSniffer(clock: { Date() })
        XCTAssertEqual(sniffer.observe(osc133("A")), [], "prompt-start A is not a command status")
        XCTAssertEqual(sniffer.observe(osc133("B")), [], "command-line-start B is not a command status")
    }

    // MARK: Full prompt cycle (A→C→D→A) yields exactly running then idle

    func testFullPromptCycleYieldsRunningThenIdle() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        var out: [WireMessage] = []
        // precmd of an empty first prompt: D;0 (ignored) then A (ignored).
        out += sniffer.observe(osc133("D;0"))
        out += sniffer.observe(osc133("A"))
        // user runs a command: preexec C.
        out += sniffer.observe(osc133("C"))
        clock.advance(11)
        // command done: precmd D;0 then A.
        out += sniffer.observe(osc133("D;0"))
        out += sniffer.observe(osc133("A"))
        XCTAssertEqual(out, [
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: 0, durationMS: 11000)),
        ])
    }

    // MARK: Split-boundary equivalence — same events feeding one byte at a time

    func testSplitAtEveryByteBoundaryProducesIdenticalEvents() {
        // Build a stream with a full C → (advance) → D cycle. Because the duration is read from
        // the clock at the moment each mark COMPLETES, advance the clock once between feeding the
        // C bytes and the D bytes — identical to the whole-chunk case.
        let cBytes = osc133("C")
        let dBytes = osc133("D;7")

        // Whole-chunk reference.
        let refClock = TestClock()
        let ref = HostOutputSniffer(clock: refClock.date)
        var reference: [WireMessage] = []
        reference += ref.observe(cBytes)
        refClock.advance(5)
        reference += ref.observe(dBytes)

        // One byte at a time, with the SAME single advance between the two marks.
        let splitClock = TestClock()
        let split = HostOutputSniffer(clock: splitClock.date)
        var got: [WireMessage] = []
        for b in cBytes { got += split.observe([b]) }
        splitClock.advance(5)
        for b in dBytes { got += split.observe([b]) }

        XCTAssertEqual(got, reference)
        XCTAssertEqual(got, [
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: 7, durationMS: 5000)),
        ])
    }

    // MARK: ST (ESC \) terminator works as well as BEL

    func testSTTerminatorRecognized() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        // ESC ] 133 ; C  ESC \   (ST instead of BEL)
        let c = Array("\u{1B}]133;C\u{1B}\\".utf8)
        XCTAssertEqual(sniffer.observe(c), [.commandStatus(.running)])
        clock.advance(1)
        let d = Array("\u{1B}]133;D;0\u{1B}\\".utf8)
        XCTAssertEqual(sniffer.observe(d), [.commandStatus(.idle(exitCode: 0, durationMS: 1000))])
    }

    // MARK: Interleaved with ordinary output + a title OSC (not a 133 mark)

    func testIgnoresNon133OSCAndPlainContent() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        // A title OSC (0;…) + plain prompt text → NO commandStatus. (FUSED-sniffer port
        // note: the old command sniffer returned [] here; the fused machine of course also
        // emits the `.title` — so the command-status assertion is the FILTERED subsequence,
        // and the title emission is asserted alongside.)
        let preamble = Array("\u{1B}]0;my title\u{07}user@host % ".utf8)
        let onPreamble = sniffer.observe(preamble)
        XCTAssertEqual(commandOnly(onPreamble), [])
        XCTAssertEqual(onPreamble, [.title("my title")])
        // Then a real C.
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)])
    }

    // MARK: Two commands back to back (state resets correctly)

    func testTwoSequentialCommandsEachMeasuredIndependently() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        // First command: 3s.
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)])
        clock.advance(3)
        XCTAssertEqual(
            sniffer.observe(osc133("D;0")),
            [.commandStatus(.idle(exitCode: 0, durationMS: 3000))],
        )
        // Second command: 7s — runningSince must have been cleared + reset.
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)])
        clock.advance(7)
        XCTAssertEqual(
            sniffer.observe(osc133("D;1")),
            [.commandStatus(.idle(exitCode: 1, durationMS: 7000))],
        )
    }

    // MARK: - OSC 9 / OSC 777 explicit notifications

    /// The `.notification` subsequence (the fused sniffer may interleave titles/bells/command status).
    private func notificationsOnly(_ messages: [WireMessage]) -> [WireMessage] {
        messages.filter { if case .notification = $0 { return true }
            return false
        }
    }

    func testOSC9EmitsNotificationWithEmptyTitle() {
        XCTAssertEqual(
            observeWhole(bytes("\u{1B}]9;build done\u{07}")),
            [.notification(title: "", body: "build done")],
        )
    }

    func testOSC9WithSTTerminator() {
        XCTAssertEqual(
            observeWhole(bytes("\u{1B}]9;tests passed\u{1B}\\")),
            [.notification(title: "", body: "tests passed")],
        )
    }

    func testOSC777NotifySubcommandEmitsTitleAndBody() {
        XCTAssertEqual(
            observeWhole(bytes("\u{1B}]777;notify;CI;all green\u{07}")),
            [.notification(title: "CI", body: "all green")],
        )
    }

    func testOSC777BodyMayContainSemicolons() {
        // maxSplits keeps the body intact even with embedded ';'.
        XCTAssertEqual(
            observeWhole(bytes("\u{1B}]777;notify;Deploy;step 1;step 2 done\u{07}")),
            [.notification(title: "Deploy", body: "step 1;step 2 done")],
        )
    }

    func testOSC777NonNotifySubcommandIgnored() {
        XCTAssertEqual(notificationsOnly(observeWhole(bytes("\u{1B}]777;precmd;something\u{07}"))), [])
    }

    func testOSC9EmptyBodyIgnored() {
        XCTAssertEqual(notificationsOnly(observeWhole(bytes("\u{1B}]9;\u{07}"))), [])
    }

    func testOSC9ProgressBarSubtypeIsNotANotification() {
        // ConEmu/iTerm2 OSC 9 is overloaded: `ESC]9;4;<state>;<pct>` is the taskbar PROGRESS-BAR protocol,
        // emitted continuously by winget / long builds — NOT a desktop notification. It must be skipped so
        // benign progress output doesn't flood the user with alerts whose body is raw text like "4;1;50".
        XCTAssertEqual(
            notificationsOnly(observeWhole(bytes("\u{1B}]9;4;1;50\u{07}"))),
            [],
            "OSC 9;4 progress update is not a notification",
        )
        XCTAssertEqual(
            notificationsOnly(observeWhole(bytes("\u{1B}]9;4\u{07}"))),
            [],
            "OSC 9;4 bare progress-clear is not a notification",
        )
        // A genuine free-text OSC 9 whose body merely STARTS with '4' (not the `4;` progress subtype) fires.
        XCTAssertEqual(
            observeWhole(bytes("\u{1B}]9;42 tests passed\u{07}")),
            [.notification(title: "", body: "42 tests passed")],
            "free-text body that only starts with a digit is still a real notification",
        )
    }

    func testNotificationSplitAcrossChunksEquivalence() {
        let raw = bytes("\u{1B}]777;notify;Title;Body text 🚀\u{07}")
        let whole = observeWhole(raw)
        for size in 1...raw.count {
            XCTAssertEqual(observeChunked(raw, size: size), whole, "diverged at chunk size \(size)")
        }
    }

    func testStringSequenceSwallowsEmbeddedNotification() {
        // A `]9;…` embedded in a DCS string body must NOT fire a phantom notification (anti-spoof,
        // same rationale as the command-status case).
        let dcsSpoof = bytes("\u{1B}P\u{1B}]9;spoofed\u{07}\u{1B}\\")
        XCTAssertEqual(notificationsOnly(observeWhole(dcsSpoof)), [])
        // A real OSC 9 after the swallowed string still fires.
        XCTAssertEqual(observeWhole(bytes("\u{1B}]9;real\u{07}")), [.notification(title: "", body: "real")])
    }

    /// R9 #4 (security): a `133;C/D` mark embedded inside a DCS/APC string body must NOT produce a phantom
    /// command-status — a conformant terminal swallows the string. So a hostile remote program cannot fake
    /// a running/idle badge (with an attacker-chosen exit code + duration).
    func testStringSequencesSwallowEmbeddedCommandStatus() {
        let clock = TestClock()
        let sniffer = HostOutputSniffer(clock: clock.date)
        // `ESC P` (DCS) … embedded `ESC]133;C BEL` … `ESC \` (ST) → swallowed, no phantom .running.
        let dcsSpoof = bytes("\u{1B}P\u{1B}]133;C\u{07}\u{1B}\\")
        XCTAssertEqual(sniffer.observe(dcsSpoof), [], "an OSC 133 embedded in a DCS string must not fire a status")
        // A REAL 133;C after the swallowed string still fires (clean resync).
        XCTAssertEqual(
            sniffer.observe(osc133("C")),
            [.commandStatus(.running)],
            "a real mark after the swallowed string still fires",
        )
    }
}
