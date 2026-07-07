import Foundation
import XCTest
@testable import SlopDeskClaudeCode

/// WF-7 terminal-mode sniffer tests. The crown jewel is the SPLIT-BOUNDARY suite:
/// feeding the SAME stream chunked at every adversarial boundary (mid-ESC, mid-CSI,
/// mid-OSC, one byte at a time) MUST produce identical events to feeding it whole.
final class TerminalModeTrackerTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"

    // MARK: Helpers

    /// Feeds `bytes` to a fresh tracker in one shot; returns all events.
    private func eventsWhole(_ bytes: [UInt8]) -> [TerminalModeEvent] {
        let t = TerminalModeTracker()
        return t.consume(bytes)
    }

    /// Feeds `bytes` to a fresh tracker split into chunks of `size`; returns all events.
    private func eventsChunked(_ bytes: [UInt8], size: Int) -> [TerminalModeEvent] {
        let t = TerminalModeTracker()
        var out: [TerminalModeEvent] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + size, bytes.count)
            out.append(contentsOf: t.consume(Array(bytes[i..<end])))
            i = end
        }
        return out
    }

    // MARK: Alt-screen enter/exit

    func testAltScreenEnterExit1049() {
        let t = TerminalModeTracker()
        XCTAssertEqual(t.mode, .shellPrompt)

        let enter = t.consume(Array("\(ESC)[?1049h".utf8))
        XCTAssertEqual(enter, [.enteredAltScreen])
        XCTAssertEqual(t.mode, .altScreen)

        let exit = t.consume(Array("\(ESC)[?1049l".utf8))
        XCTAssertEqual(exit, [.exitedAltScreen])
        XCTAssertEqual(t.mode, .shellPrompt)
    }

    func testLegacyAltScreenModes47And1047() {
        for mode in [47, 1047] {
            let t = TerminalModeTracker()
            XCTAssertEqual(t.consume(Array("\(ESC)[?\(mode)h".utf8)), [.enteredAltScreen])
            XCTAssertEqual(t.mode, .altScreen)
            XCTAssertEqual(t.consume(Array("\(ESC)[?\(mode)l".utf8)), [.exitedAltScreen])
            XCTAssertEqual(t.mode, .shellPrompt)
        }
    }

    func testNoDuplicateAltScreenWhenAlreadyInMode() {
        let t = TerminalModeTracker()
        XCTAssertEqual(t.consume(Array("\(ESC)[?1049h".utf8)), [.enteredAltScreen])
        // A second enter while already in alt-screen emits nothing.
        XCTAssertEqual(t.consume(Array("\(ESC)[?1049h".utf8)), [])
        XCTAssertEqual(t.mode, .altScreen)
    }

    // MARK: Bracketed paste (DECSET/DECRST 2004)

    /// `ESC[?2004h` enables bracketed-paste mode; `ESC[?2004l` disables it. It is a passive flag (no event)
    /// and independent of the alt-screen mode.
    func testBracketedPasteEnableDisable() {
        let t = TerminalModeTracker()
        XCTAssertFalse(t.bracketedPasteActive)

        // Enabling bracketed paste emits NO mode event and leaves `.mode` alone.
        XCTAssertEqual(t.consume(Array("\(ESC)[?2004h".utf8)), [])
        XCTAssertTrue(t.bracketedPasteActive)
        XCTAssertEqual(t.mode, .shellPrompt)

        XCTAssertEqual(t.consume(Array("\(ESC)[?2004l".utf8)), [])
        XCTAssertFalse(t.bracketedPasteActive)
    }

    /// A single CSI can carry both alt-screen and bracketed params (`?1049;2004h`): the alt-screen event
    /// still fires exactly once AND the bracketed flag flips.
    func testBracketedPasteWithAltScreenInOneCSI() {
        let t = TerminalModeTracker()
        XCTAssertEqual(t.consume(Array("\(ESC)[?1049;2004h".utf8)), [.enteredAltScreen])
        XCTAssertEqual(t.mode, .altScreen)
        XCTAssertTrue(t.bracketedPasteActive)
    }

    /// `reset()` (session boundary) clears the bracketed flag — a fresh shell re-advertises it.
    func testBracketedPasteClearedOnReset() {
        let t = TerminalModeTracker()
        t.consume(Array("\(ESC)[?2004h".utf8))
        XCTAssertTrue(t.bracketedPasteActive)
        t.reset()
        XCTAssertFalse(t.bracketedPasteActive)
    }

    // MARK: DECCKM application cursor keys (DECSET/DECRST 1) — docs/29 #6

    /// `ESC[?1h` enables application cursor keys; `ESC[?1l` disables them. Passive flag (no event),
    /// same contract as bracketed paste.
    func testCursorKeysApplicationEnableDisable() {
        let t = TerminalModeTracker()
        XCTAssertFalse(t.cursorKeysApplication)

        XCTAssertEqual(t.consume(Array("\(ESC)[?1h".utf8)), [])
        XCTAssertTrue(t.cursorKeysApplication)
        XCTAssertEqual(t.mode, .shellPrompt)

        XCTAssertEqual(t.consume(Array("\(ESC)[?1l".utf8)), [])
        XCTAssertFalse(t.cursorKeysApplication)
    }

    /// A single CSI can carry DECCKM alongside alt-screen (`?1049;1h` — vim's actual startup shape):
    /// the alt-screen event still fires once AND the cursor-key flag flips. Also pins that param 1049
    /// does NOT match param 1 (exact-integer, not substring, matching).
    func testCursorKeysApplicationWithAltScreenInOneCSI() {
        let t = TerminalModeTracker()
        XCTAssertEqual(t.consume(Array("\(ESC)[?1049h".utf8)), [.enteredAltScreen])
        XCTAssertFalse(t.cursorKeysApplication, "param 1049 must not flip DECCKM")

        XCTAssertEqual(t.consume(Array("\(ESC)[?1049;1h".utf8)), [])
        XCTAssertTrue(t.cursorKeysApplication)
        XCTAssertEqual(t.mode, .altScreen)
    }

    /// `reset()` (session boundary) clears the DECCKM flag — a dropped session inside vim must not
    /// leave application-mode arrows latched for the fresh shell.
    func testCursorKeysApplicationClearedOnReset() {
        let t = TerminalModeTracker()
        t.consume(Array("\(ESC)[?1h".utf8))
        XCTAssertTrue(t.cursorKeysApplication)
        t.reset()
        XCTAssertFalse(t.cursorKeysApplication)
    }

    /// The sequence split at every possible chunk boundary still flips the flag (the tracker's
    /// byte-at-a-time invariant extends to the passive flags).
    func testCursorKeysApplicationSplitAcrossChunks() {
        let bytes = Array("\(ESC)[?1h".utf8)
        for split in 1..<bytes.count {
            let t = TerminalModeTracker()
            t.consume(Array(bytes[..<split]))
            t.consume(Array(bytes[split...]))
            XCTAssertTrue(t.cursorKeysApplication, "split at \(split) must still set DECCKM")
        }
    }

    /// A `?1h` embedded in a DCS string body is opaque content — it must NOT flip the flag (the same
    /// string-consume rule that protects alt-screen tracking).
    func testCursorKeysApplicationNotFlippedFromStringBody() {
        let t = TerminalModeTracker()
        t.consume(Array("\(ESC)P\(ESC)[?1h\(ESC)\\".utf8))
        XCTAssertFalse(t.cursorKeysApplication)
    }

    // MARK: OSC 133

    func testOSC133PromptCycleWithExitCode() {
        let t = TerminalModeTracker()
        let stream = "\(ESC)]133;A\(BEL)" + "user@host$ " + "\(ESC)]133;B\(BEL)"
            + "ls -la\n" + "\(ESC)]133;C\(BEL)" + "drwx...\n" + "\(ESC)]133;D;0\(BEL)"
        let events = t.consume(Array(stream.utf8))
        XCTAssertEqual(events, [
            .promptStart, .commandStart, .commandStarted, .commandFinished(exitCode: 0),
        ])
    }

    func testOSC133ExitCodeNonZero() {
        let t = TerminalModeTracker()
        XCTAssertEqual(
            t.consume(Array("\(ESC)]133;D;1\(BEL)".utf8)),
            [.commandFinished(exitCode: 1)],
        )
    }

    func testOSC133FinishedNoExitCode() {
        let t = TerminalModeTracker()
        XCTAssertEqual(
            t.consume(Array("\(ESC)]133;D\(BEL)".utf8)),
            [.commandFinished(exitCode: nil)],
        )
    }

    func testOSC133TerminatedByST() {
        // OSC may be terminated by ST (`ESC\`) instead of BEL.
        let t = TerminalModeTracker()
        XCTAssertEqual(
            t.consume(Array("\(ESC)]133;A\(ESC)\\".utf8)),
            [.promptStart],
        )
    }

    func testOSC133WithExtraKeyValueFields() {
        // `;D;0;aid=...` — extra fields after the exit code are ignored.
        let t = TerminalModeTracker()
        XCTAssertEqual(
            t.consume(Array("\(ESC)]133;D;0;aid=12345\(BEL)".utf8)),
            [.commandFinished(exitCode: 0)],
        )
    }

    // MARK: Interleaved real-world stream

    func testInterleavedAltScreenAndOSCAndText() {
        let t = TerminalModeTracker()
        let stream =
            "welcome\n"
                + "\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)vim file\n\(ESC)]133;C\(BEL)"
                + "\(ESC)[?1049h" // vim enters alt-screen
                + "\(ESC)[2J~\n~\n" // some vim drawing (unknown CSI + text)
                + "\(ESC)[?1049l" // vim exits
                + "\(ESC)]133;D;0\(BEL)"
        let events = t.consume(Array(stream.utf8))
        XCTAssertEqual(events, [
            .promptStart, .commandStart, .commandStarted,
            .enteredAltScreen, .exitedAltScreen,
            .commandFinished(exitCode: 0),
        ])
        XCTAssertEqual(t.mode, .shellPrompt)
    }

    // MARK: Split-boundary equivalence — THE critical property

    func testSplitBoundaryEquivalenceForRichStream() {
        let stream =
            "boot\n"
                + "\(ESC)]133;A\(BEL)user@host:~$ \(ESC)]133;B\(BEL)"
                + "claude\n\(ESC)]133;C\(BEL)"
                + "\(ESC)[?1049h" // claude enters fullscreen
                + "\(ESC)[1;1H\(ESC)[38;2;255;0;0mhello\(ESC)[0m" // SGR truecolor + cursor
                + "\(ESC)]0;Claude Code\(BEL)" // OSC 0 title (unknown OSC, must be skipped)
                + "\(ESC)[?1049l" // exit fullscreen
                + "\(ESC)]133;D;42\(BEL)"
        let bytes = Array(stream.utf8)
        let expected = eventsWhole(bytes)

        XCTAssertEqual(expected, [
            .promptStart, .commandStart, .commandStarted,
            .enteredAltScreen, .exitedAltScreen,
            .commandFinished(exitCode: 42),
        ])

        // Every chunk size from 1 (one byte at a time) up to the full length must yield
        // the SAME events — proves no marker is missed or duplicated at any boundary.
        for size in 1...bytes.count {
            let chunked = eventsChunked(bytes, size: size)
            XCTAssertEqual(chunked, expected, "chunk size \(size) diverged")
        }
    }

    func testSplitMidEscapeSequence() {
        // Deliberately split right after the ESC, and right after the `[?104`, etc.
        let bytes = Array("\(ESC)[?1049h\(ESC)[?1049l".utf8)
        let expected: [TerminalModeEvent] = [.enteredAltScreen, .exitedAltScreen]
        for size in 1...bytes.count {
            XCTAssertEqual(eventsChunked(bytes, size: size), expected, "size \(size)")
        }
    }

    func testSplitMidOSCPayload() {
        let bytes = Array("\(ESC)]133;D;7\(BEL)".utf8)
        let expected: [TerminalModeEvent] = [.commandFinished(exitCode: 7)]
        for size in 1...bytes.count {
            XCTAssertEqual(eventsChunked(bytes, size: size), expected, "size \(size)")
        }
    }

    func testPartialSequenceAtEndOfChunkNeverMisfires() {
        let t = TerminalModeTracker()
        // Feed a partial alt-screen enter; no event yet, mode unchanged.
        XCTAssertEqual(t.consume(Array("\(ESC)[?10".utf8)), [])
        XCTAssertEqual(t.mode, .shellPrompt)
        // Complete it in the next chunk.
        XCTAssertEqual(t.consume(Array("49h".utf8)), [.enteredAltScreen])
        XCTAssertEqual(t.mode, .altScreen)
    }

    // MARK: Tolerance — unknown sequences + raw / high-bit bytes

    func testUnknownCSISequencesDoNotBreakTracking() {
        let t = TerminalModeTracker()
        let stream =
            "\(ESC)[2J" // clear screen (unknown to us)
            + "\(ESC)[38;5;201m" // 256-color SGR
            + "\(ESC)[1;31;42m" // SGR combo
            + "\(ESC)[?2004h" // bracketed paste mode ON (DEC private, NOT alt-screen)
            + "\(ESC)[?25l" // hide cursor (DEC private, NOT alt-screen)
            + "\(ESC)[?1049h" // the one we DO track
        let events = t.consume(Array(stream.utf8))
        // Only the 1049 enter should surface; ?2004 / ?25 must be ignored.
        XCTAssertEqual(events, [.enteredAltScreen])
        XCTAssertEqual(t.mode, .altScreen)
    }

    func testUnknownOSCSequencesSkipped() {
        let t = TerminalModeTracker()
        let stream =
            "\(ESC)]0;a window title\(BEL)" // OSC 0 (title)
            + "\(ESC)]8;;https://example.com\(BEL)" // OSC 8 (hyperlink)
            + "\(ESC)]52;c;BASE64==\(BEL)" // OSC 52 (clipboard)
            + "\(ESC)]133;A\(BEL)" // the one we track
        XCTAssertEqual(t.consume(Array(stream.utf8)), [.promptStart])
    }

    func testHighBitAndUTF8BytesPassThrough() {
        let t = TerminalModeTracker()
        // Emoji + accented text + raw high bytes interleaved with a tracked marker.
        var bytes = Array("café 🚀 ".utf8)
        bytes.append(contentsOf: [0xFF, 0x80, 0xC0]) // raw high-bit / invalid UTF-8
        bytes.append(contentsOf: Array("\(ESC)[?1049h".utf8))
        bytes.append(contentsOf: Array("日本語".utf8))
        let events = t.consume(bytes)
        XCTAssertEqual(events, [.enteredAltScreen])
        XCTAssertEqual(t.mode, .altScreen)
    }

    func testMalformedUnterminatedOSCDoesNotWedgeParser() {
        let t = TerminalModeTracker()
        // A huge unterminated OSC (exceeds the cap) followed by a real tracked marker.
        let junk = String(repeating: "x", count: 1000)
        let stream = "\(ESC)]999;\(junk)" + "\(ESC)[?1049h"
        let events = t.consume(Array(stream.utf8))
        // The overlong OSC is abandoned at the cap; the real ESC re-syncs and the
        // alt-screen marker is still detected.
        XCTAssertEqual(events, [.enteredAltScreen])
        XCTAssertEqual(t.mode, .altScreen)
    }

    // MARK: Unterminated OSC abutting an ESC-introduced sequence (issue #1)

    func testUnterminatedOSCThenAltScreenEnterNotLost() {
        // `ESC]133` (no terminator) directly followed by `ESC[?1049h`. The stray ESC ends
        // the bogus OSC, but it ALSO introduces the alt-screen CSI — that marker must not
        // be dropped, and the mode must flip to alt-screen.
        let t = TerminalModeTracker()
        let bytes = Array("\(ESC)]133".utf8) + Array("\(ESC)[?1049h".utf8)
        let events = t.consume(bytes)
        XCTAssertEqual(events, [.enteredAltScreen])
        XCTAssertEqual(t.mode, .altScreen)
    }

    func testUnterminatedOSCThenAltScreenEnterSplitConsistent() {
        // Same input must yield the same events at every chunk boundary.
        let bytes = Array("\(ESC)]133".utf8) + Array("\(ESC)[?1049h".utf8)
        let expected: [TerminalModeEvent] = [.enteredAltScreen]
        for size in 1...bytes.count {
            XCTAssertEqual(eventsChunked(bytes, size: size), expected, "size \(size)")
        }
    }

    func testUnterminatedOSC133AThenValidOSC133B() {
        // An unterminated `ESC]133;A` immediately followed by a valid `ESC]133;B BEL`.
        // The stray ESC ends the A-OSC; the following `]133;B` must still be parsed.
        let t = TerminalModeTracker()
        let bytes = Array("\(ESC)]133;A".utf8) + Array("\(ESC)]133;B\(BEL)".utf8)
        XCTAssertEqual(t.consume(bytes), [.promptStart, .commandStart])
    }

    func testUnterminatedOSC133AThenValidOSC133BSplitConsistent() {
        let bytes = Array("\(ESC)]133;A".utf8) + Array("\(ESC)]133;B\(BEL)".utf8)
        let expected: [TerminalModeEvent] = [.promptStart, .commandStart]
        for size in 1...bytes.count {
            XCTAssertEqual(eventsChunked(bytes, size: size), expected, "size \(size)")
        }
    }

    func testUnterminatedOSCThenTwoByteEscapeThenBEL() {
        // `ESC]133;A` then `ESC X` (a non-`\`, non-bracket 2-byte escape that we do NOT
        // track) then a `BEL`. The A-mark fires; the `ESC X` is consumed cleanly and the
        // trailing BEL is harmless ground content. No spurious or dropped markers.
        let t = TerminalModeTracker()
        let bytes = Array("\(ESC)]133;A".utf8) + Array("\(ESC)X".utf8) + Array(BEL.utf8)
        XCTAssertEqual(t.consume(bytes), [.promptStart])
        XCTAssertEqual(t.mode, .shellPrompt)
    }

    func testDoubleEscapeThenBackslashStillTerminatesST() {
        // Regression: `ESC]133;A` then `ESC ESC \`. The first ESC enters `.oscEscape`;
        // the second ESC (not `\`) ends the OSC and re-enters `.escape`; the `\` is then a
        // lone nF-escape final and is consumed cleanly. The A-mark still fires once.
        let t = TerminalModeTracker()
        let bytes = Array("\(ESC)]133;A".utf8) + Array("\(ESC)\(ESC)\\".utf8)
        XCTAssertEqual(t.consume(bytes), [.promptStart])
    }

    // MARK: AsyncStream façade

    func testAsyncStreamFacadeYieldsEventsInOrder() async {
        let stream = TerminalModeStream()
        var collected: [TerminalModeEvent] = []
        let consumer = Task {
            var out: [TerminalModeEvent] = []
            for await e in stream.events { out.append(e) }
            return out
        }
        stream.feed(Array("\(ESC)]133;A\(BEL)".utf8))
        stream.feed(Array("\(ESC)[?1049h".utf8))
        stream.feed(Array("\(ESC)[?1049l".utf8))
        stream.finish()
        collected = await consumer.value
        XCTAssertEqual(collected, [.promptStart, .enteredAltScreen, .exitedAltScreen])
    }

    /// R9 #4 (security): a DCS/SOS/PM/APC string body is opaque — an `ESC[?1049h` (alt-screen) embedded in
    /// one must NOT flip the tracked mode (else a malicious program could force the input box's mode). A
    /// REAL alt-screen sequence after the swallowed string still works (clean resync), and the spoof stays
    /// split-boundary-equivalent.
    func testStringSequencesDoNotFlipModeFromEmbeddedCSI() {
        let t = TerminalModeTracker()
        // `ESC P` (DCS) … embedded `ESC[?1049h` … `ESC \` (ST) → swallowed; mode unchanged.
        let dcsSpoof = Array("\(ESC)P\(ESC)[?1049h\(ESC)\\".utf8)
        XCTAssertEqual(t.consume(dcsSpoof), [], "an alt-screen CSI embedded in a DCS string must not enter alt-screen")
        XCTAssertEqual(t.mode, .shellPrompt, "mode unchanged by the opaque string body")
        // A REAL alt-screen enter after the swallowed string still fires.
        XCTAssertEqual(t.consume(Array("\(ESC)[?1049h".utf8)), [.enteredAltScreen])
        XCTAssertEqual(t.mode, .altScreen)
        // Split-boundary equivalence holds for the spoof sequence too (the crown-jewel invariant).
        XCTAssertEqual(eventsChunked(dcsSpoof, size: 1), [], "byte-at-a-time produces the same (empty) result")
    }
}
