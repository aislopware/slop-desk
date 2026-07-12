import Foundation
import XCTest
@testable import SlopDeskHost

/// The PURE cold-reattach scrollback distiller: raw wire bytes (prompt + B→C editing churn + C→D output)
/// → clean transcript (prompt kept, B→C churn collapsed to the `133;E` committed command, output kept).
final class ScrollbackDistillerTests: XCTestCase {
    // MARK: Mark builders (mirror the shim's OSC-133 wire form)

    /// `ESC ] 133 ; <body> BEL` (BEL terminator).
    private func mark(_ body: String) -> String { "\u{1B}]133;\(body)\u{07}" }
    /// `ESC ] 133 ; <body> ESC \` (ST terminator).
    private func markST(_ body: String) -> String { "\u{1B}]133;\(body)\u{1B}\\" }

    private func distill(_ string: String) -> String {
        String(bytes: ScrollbackDistiller.distill(Data(string.utf8)), encoding: .utf8) ?? ""
    }

    private func distill(_ bytes: [UInt8]) -> String {
        String(bytes: ScrollbackDistiller.distill(Data(bytes)), encoding: .utf8) ?? ""
    }

    // MARK: Baselines

    func testEmptyInput() {
        XCTAssertEqual(ScrollbackDistiller.distill(Data()), Data())
    }

    func testNoMarksPassThroughVerbatim() {
        // A stream with no OSC-133 marks (raw output) is untouched.
        XCTAssertEqual(distill("hello world\n"), "hello world\n")
        XCTAssertEqual(distill("a\u{1B}[31mred\u{1B}[0mb"), "a\u{1B}[31mred\u{1B}[0mb")
    }

    func testNonSemanticOSCPreserved() {
        // An OSC title (OSC 0) is NOT a 133 mark → preserved verbatim.
        XCTAssertEqual(distill("\u{1B}]0;my title\u{07}text"), "\u{1B}]0;my title\u{07}text")
    }

    // MARK: The core collapse

    func testCommandSpanCollapsedToCommittedCommand() {
        // Prompt (A→B) kept; the B→C editing region (here: garbage echo) DROPPED and replaced by the
        // `133;E` command text + CRLF; the C→D output kept verbatim. The `133;A` prompt mark is RE-EMITTED
        // (libghostty counts prompts by it) so cold-reattach prompt/block jumps still anchor.
        let input =
            "\(mark("A"))~/proj ❯ \(mark("B"))ggii...garbage-echo...\(mark("E;git status"))\(mark("C"))On branch main\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "\(mark("A"))~/proj ❯ git status\r\nOn branch main\n")
    }

    func testTabCompletionMenuDropped() {
        // Simulate a tab-completion interaction inside B→C: the menu is drawn with newlines + cursor
        // motion, then would be cleared. ALL of it is dropped; only the committed command survives.
        let menu = "git ch\n  checkout  cherry  cherry-pick\u{1B}[2A\u{1B}[J"
        let input =
            "\(mark("A"))$ \(mark("B"))\(menu)\(mark("E;git checkout main"))\(mark("C"))Switched to branch 'main'\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "\(mark("A"))$ git checkout main\r\nSwitched to branch 'main'\n")
    }

    func testOutputColoursPreserved() {
        // SGR colour runs in the C→D output must survive (unlike in B→C, where they are churn).
        let input =
            "\(mark("A"))$ \(mark("B"))x\(mark("E;ls"))\(mark("C"))\u{1B}[01;34mdir\u{1B}[0m file\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "\(mark("A"))$ ls\r\n\u{1B}[01;34mdir\u{1B}[0m file\n")
    }

    func testNonSemanticOSCInOutputPreserved() {
        // A hyperlink OSC (OSC 8) emitted as command OUTPUT is kept.
        let link = "\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\"
        let input = "\(mark("A"))$ \(mark("B"))x\(mark("E;echo"))\(mark("C"))\(link)\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "\(mark("A"))$ echo\r\n\(link)\n")
    }

    func testMultipleCommandsCollapsedIndependently() {
        let input =
            "\(mark("A"))$ \(mark("B"))junk1\(mark("E;pwd"))\(mark("C"))/home\n\(mark("D;0"))"
                + "\(mark("A"))$ \(mark("B"))junk2\(mark("E;whoami"))\(mark("C"))root\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "\(mark("A"))$ pwd\r\n/home\n\(mark("A"))$ whoami\r\nroot\n")
    }

    // MARK: Fallback safety (no committed command)

    func testNoExplicitCommandFallsBackToVerbatimSpan() {
        // A B→C span with NO `133;E`: the raw editing bytes pass through verbatim (never lost, never
        // invented). Byte-identical to the pre-distiller replay for a non-shim shell.
        let input = "\(mark("A"))$ \(mark("B"))ls -la\r\n\(mark("C"))total 0\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "\(mark("A"))$ ls -la\r\ntotal 0\n")
    }

    func testPromptRedrawResetsInputBuffer() {
        // A re-fired `B` (zle reset-prompt redraw) discards the partial B→C bytes captured so far; the
        // final `E` command is what survives.
        let input =
            "\(mark("A"))$ \(mark("B"))par\(mark("B"))partial-echo\(mark("E;make test"))\(mark("C"))ok\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "\(mark("A"))$ make test\r\nok\n")
    }

    // MARK: E unescape (byte-identical to the segmenter)

    func testExplicitCommandUnescaped() {
        // The shim escapes `;`, `\`, ESC, BEL, CR, LF as `\xNN`. `echo a;b` → `echo a\x3bb`.
        let input = "\(mark("A"))$ \(mark("B"))z\(mark("E;echo a\\x3bb"))\(mark("C"))a;b\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "\(mark("A"))$ echo a;b\r\na;b\n")
    }

    func testExplicitCommandWithSTTerminator() {
        // The mark may be closed by ST (`ESC \`) instead of BEL — both must parse.
        let input =
            "\(markST("A"))$ \(markST("B"))w\(markST("E;date"))\(markST("C"))Mon\n\(markST("D;0"))"
        XCTAssertEqual(distill(input), "\(markST("A"))$ date\r\nMon\n")
    }

    // MARK: Partial / mid-stream streams (scrollback ring can start mid-history)

    func testStreamStartingMidOutputPassesThrough() {
        // The ring's oldest entry can begin mid-output (line-aligned, but after a prior command's C).
        // With no leading A/B we are in the idle/passthrough phase → verbatim until the next mark cycle.
        let input = "…tail of prior output\n\(mark("A"))$ \(mark("B"))q\(mark("E;id"))\(mark("C"))uid=0\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "…tail of prior output\n\(mark("A"))$ id\r\nuid=0\n")
    }

    func testUnterminatedCommandSpanAtEndEmitsRawTail() {
        // A B→C span still open at end-of-buffer (the live command line being edited when the ring ended)
        // with no committed E: emit the raw tail so nothing is lost.
        let input = "\(mark("A"))$ \(mark("B"))half-typed-cmd"
        XCTAssertEqual(distill(input), "\(mark("A"))$ half-typed-cmd")
    }

    func testMalformedTrailingEscapeDoesNotTrap() {
        // A bare trailing ESC / unterminated OSC must not trap; the partial sequence is flushed.
        XCTAssertEqual(distill("done\u{1B}"), "done\u{1B}")
        XCTAssertEqual(distill("x\u{1B}]0;no-term"), "x\u{1B}]0;no-term")
    }

    func testEmbedded133InTitleDoesNotSegment() {
        // A `133;C`-looking substring INSIDE a non-133 OSC (title) is part of that OSC's payload, not a
        // mark — the whole title is preserved and no phantom collapse happens.
        let input = "\u{1B}]0;prompt 133;C here\u{07}visible"
        XCTAssertEqual(distill(input), "\u{1B}]0;prompt 133;C here\u{07}visible")
    }

    // MARK: Overflow fallback

    func testOversizedInputSpanFallsBackToPassthrough() {
        // A B→C span larger than the fallback cap (256 KiB) overflows → the raw bytes pass through (the
        // giant editing span won't collapse cleanly; never dropped). The C still ends the span.
        let big = String(repeating: "x", count: 300 * 1024)
        let input = "\(mark("A"))$ \(mark("B"))\(big)\(mark("E;huge"))\(mark("C"))out\n\(mark("D;0"))"
        let result = distill(input)
        // The overflowed raw span is present; output follows.
        XCTAssertTrue(result.contains(big), "oversized span should pass through verbatim")
        XCTAssertTrue(result.hasSuffix("out\n"))
    }

    // MARK: Input-span flush on D / A (no C) — the "never lost output" fallback

    func testEmptyEnterSpanFlushedOnD() {
        // An empty-Enter line: `B` (from $PROMPT) → the accept-line "\r\n" echo → precmd `D;0` (NO preexec,
        // so NO `E`/`C`). The buffered "\r\n" must be FLUSHED on the `D`, not dropped — else consecutive
        // prompts jam onto one line in the restored scrollback.
        let input = "\(mark("A"))~ ❯ \(mark("B"))\r\n\(mark("D;0"))\(mark("A"))~ ❯ "
        XCTAssertEqual(distill(input), "\(mark("A"))~ ❯ \r\n\(mark("A"))~ ❯ ")
    }

    func testCtrlCSpanFlushedOnClosingA() {
        // A typed-then-Ctrl-C'd line closed directly by the NEXT prompt's `A` (no `C`, no `D` seen before it):
        // the echoed "sleep 99^C\r\n" must survive rather than vanish + concatenate the two prompts.
        let input = "\(mark("A"))$ \(mark("B"))sleep 99^C\r\n\(mark("A"))$ "
        XCTAssertEqual(distill(input), "\(mark("A"))$ sleep 99^C\r\n\(mark("A"))$ ")
    }

    // MARK: DCS/SOS/PM/APC string-swallow — parity with HostOutputSniffer

    func testDCSStringBodyDoesNotSpoofMarkAndOutputSurvives() {
        // A DCS passthrough string whose BODY contains an `ESC]133;B` must NOT flip the distiller into
        // command-input suppression: the body passes through verbatim, the following real output is kept,
        // and a subsequent real `133;D` is consumed (zero-width). Without the string-consume state the
        // embedded `B` sets suppress=true and the real output is orphaned + dropped at the `D`.
        let input = "\u{1B}P\u{1B}]133;B\u{07}REALOUTPUT\u{1B}\\\(mark("D;0"))"
        // Everything but the trailing real `133;D` mark passes through verbatim; the embedded `133;B` is
        // opaque DCS-body text (BEL terminates the DCS), never a phase mark.
        XCTAssertEqual(distill(input), "\u{1B}P\u{1B}]133;B\u{07}REALOUTPUT\u{1B}\\")
    }

    func testDCSStringBodyPreservedVerbatimWhenIdle() {
        // A well-formed ST-terminated DCS with no embedded marks passes through untouched in the idle phase.
        let dcs = "\u{1B}Pcontrol-string-body\u{1B}\\"
        XCTAssertEqual(distill("before\(dcs)after"), "before\(dcs)after")
    }

    // MARK: Nasty-corpus exact-byte pin (allocation-refactor guard)

    /// EXACT-BYTE pin over a representative nasty corpus, expected output constructed by hand from
    /// the documented semantics (idle verbatim, `A` re-emitted, B→C collapsed to the `E` command +
    /// CRLF, C→D output verbatim incl. every control sequence, `B`/`E`/`C`/`D` marks zero-width, a
    /// no-`E` span verbatim, trailing broken escape flushed). Any refactor of the byte loop that
    /// changes a single output byte fails here. Covers SGR-heavy output, OSC/DCS query bytes riding
    /// the OUTPUT span (the distiller must NOT strip them — that is the stripper's job), an APC body
    /// with an embedded fake `133` mark, raw multi-byte UTF-8, and `\xNN` command unescaping.
    func testNastyCorpusExactBytesPinned() {
        let pre = "…mid-stream tail ✓ \u{1B}[31mred\u{1B}[0m\n"
        let prompt = "\u{1B}[1;32m~/proj\u{1B}[0m ❯ "
        let churn = "g\u{1B}[90mit statu\u{1B}[0m\rgit status\u{1B}[K\t\nmenu a b c\u{1B}[2A\u{1B}[J"
        // Output span: SGR + hyperlink + DCS query + APC with an embedded fake mark + UTF-8. All verbatim.
        let output = "\u{1B}[01;34mdir\u{1B}[0m tệp ✓\n"
            + "\u{1B}]8;;http://x\u{1B}\\L\u{1B}]8;;\u{1B}\\"
            + "\u{1B}P+q544e\u{1B}\\"
            + "\u{1B}_G\u{1B}]133;B;fake\u{1B}\\real tail\n"
        let post = "after\n"
        let trailing = "\u{1B}]0;unterminated" // broken trailing OSC — flushed verbatim

        // Cycle 1: full A→B→churn→E→C→output→D with an escaped `;` in the committed command.
        // Cycle 2: no `E` → the raw B→C bytes pass through verbatim (fallback), then output.
        let input = pre
            + mark("A") + prompt + mark("B") + churn + mark("E;echo a\\x3bb") + mark("C") + output + mark("D;0")
            + mark("A") + "$ " + mark("B") + "ls -l\r\n" + mark("C") + "total 0\n" + mark("D;1")
            + post + trailing
        let expected = pre
            + mark("A") + prompt + "echo a;b\r\n" + output
            + mark("A") + "$ " + "ls -l\r\n" + "total 0\n"
            + post + trailing
        XCTAssertEqual(ScrollbackDistiller.distill(Data(input.utf8)), Data(expected.utf8))
    }
}
