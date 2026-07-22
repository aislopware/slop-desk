import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``SyncInputByteFilter`` — the sync-input fan-out mirrors KEYBOARD bytes only: terminal query
/// replies (CPR/DA/DSR/XTWINOPS/DECRPM/kitty-flags), mouse reports (SGR + X10), focus events, and
/// OSC/DCS reply bodies are stripped from the mirrored copy; everything a keyboard or paste produces
/// survives byte-exact.
final class SyncInputByteFilterTests: XCTestCase {
    private func filter(_ s: String) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: SyncInputByteFilter.keyboardOnly(Data(s.utf8)), as: UTF8.self)
    }

    // MARK: Keyboard bytes survive

    /// Plain text, control bytes, SS3 keys, CSI arrows/nav/`~` keys, and kitty `CSI u` keystrokes all
    /// pass through byte-exact — the identity fast path for real typing.
    func testKeyboardBytesSurvive() {
        for kept in [
            "ls -la\r",
            "\u{03}", // Ctrl-C
            "\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D", // arrows
            "\u{1B}[1;5C", // ctrl-arrow
            "\u{1B}[3~\u{1B}[5~\u{1B}[6~", // delete / page keys
            "\u{1B}OP\u{1B}OQ\u{1B}OR", // SS3 F1–F3 (plain F3 is SS3, NOT the CPR shape)
            "\u{1B}[97;5u", // kitty-encoded Ctrl-A (non-private `u` = keystroke)
            "\u{1B}a", // meta-prefixed char
        ] {
            XCTAssertEqual(filter(kept), kept, "\(kept.debugDescription) must survive the mirror")
        }
    }

    /// Bracketed paste (wrappers + body) survives — "type once, run everywhere" covers paste.
    func testBracketedPasteSurvives() {
        let paste = "\u{1B}[200~echo hello\u{1B}[201~"
        XCTAssertEqual(filter(paste), paste)
    }

    // MARK: Reports and replies are stripped

    /// SGR mouse reports (`ESC[<…M/m`) — the field-observed scroll burst — are stripped.
    func testStripsSGRMouseReports() {
        let burst = "\u{1B}[<65;31;18M\u{1B}[<65;31;18m\u{1B}[<0;5;7M"
        XCTAssertEqual(filter("a" + burst + "b"), "ab")
    }

    /// X10 mouse (`ESC[M` + 3 raw payload bytes) is stripped INCLUDING its payload bytes, which are
    /// not CSI params and would otherwise leak through as printable garbage.
    func testStripsX10MouseWithPayload() {
        let x10 = "\u{1B}[M !\"" // button 0x20, x 0x21, y 0x22
        XCTAssertEqual(filter("a" + x10 + "b"), "ab")
    }

    /// Terminal query replies — CPR, DSR status, DA1/DA2, XTWINOPS, DECRPM, kitty-flags — are stripped.
    func testStripsQueryReplies() {
        for reply in [
            "\u{1B}[24;80R", // CPR
            "\u{1B}[0n", // DSR ok
            "\u{1B}[?1;2c", // DA1
            "\u{1B}[>0;276;0c", // DA2
            "\u{1B}[8;33;96t", // XTWINOPS text-area size (the field-observed shape)
            "\u{1B}[4;1452;1632t", // XTWINOPS pixel size
            "\u{1B}[?2026;1$y", // DECRPM
            "\u{1B}[?1u", // kitty keyboard-flags reply (private `u`)
        ] {
            XCTAssertEqual(filter("x" + reply + "y"), "xy", "\(reply.debugDescription) must be stripped")
        }
    }

    /// Focus in/out events (`ESC[I` / `ESC[O`, exactly — no params) are stripped.
    func testStripsFocusEvents() {
        XCTAssertEqual(filter("a\u{1B}[Ib\u{1B}[Oc"), "abc")
    }

    /// OSC and DCS reply bodies (color queries, OSC 52 clipboard, XTGETTCAP) are stripped whole.
    func testStripsStringReplies() {
        let osc = "\u{1B}]11;rgb:1e1e/1e1e/2e2e\u{07}"
        let oscST = "\u{1B}]52;c;aGVsbG8=\u{1B}\\"
        let dcs = "\u{1B}P1+r544e\u{1B}\\"
        XCTAssertEqual(filter("a" + osc + oscST + dcs + "b"), "ab")
    }

    /// The field-observed garbage — a window report + SGR scroll burst that EXECUTED as a command in
    /// the sibling — is stripped entirely; the surrounding keystrokes survive.
    func testStripsFieldObservedGarbageBurst() {
        let garbage = "\u{1B}[8;33;96t\u{1B}[4;1452;1632t"
            + "\u{1B}[<65;31;18M\u{1B}[<65;31;18M\u{1B}[<66;31;18M"
        XCTAssertEqual(filter("cc" + garbage + "\r"), "cc\r")
    }

    // MARK: Boundaries

    /// A truncated trailing sequence passes through verbatim (input arrives one whole event per chunk;
    /// passthrough is the least surprising fallback, mirroring the replay strippers' convention).
    func testTruncatedTrailingSequencePassesThrough() {
        for cut in ["tail\u{1B}[38;5", "tail\u{1B}]11;rgb", "tail\u{1B}"] {
            XCTAssertEqual(filter(cut), cut, "\(cut.debugDescription) must pass through")
        }
    }

    /// Empty input is empty output.
    func testEmptyIsEmpty() {
        XCTAssertEqual(SyncInputByteFilter.keyboardOnly(Data()), Data())
    }

    /// Modified F3 (`ESC[1;2R`) shares the CPR shape and is dropped from the MIRROR — the documented
    /// accepted gap (the source pane still receives it; plain F3 rides SS3 and survives).
    func testModifiedF3IsTheDocumentedAcceptedGap() {
        XCTAssertEqual(filter("a\u{1B}[1;2Rb"), "ab")
        XCTAssertEqual(filter("a\u{1B}ORb"), "a\u{1B}ORb", "plain SS3 F3 survives")
    }
}
