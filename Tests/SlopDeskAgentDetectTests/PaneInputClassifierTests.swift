import XCTest
@testable import SlopDeskAgentDetect

/// The classifier decides whether one client→PTY input chunk carries a USER KEYSTROKE, as opposed
/// to the terminal emulator's own automatic replies (focus in/out, cursor-position / device / mode
/// reports, mouse wheel) that ride the same input frames with no human action behind them. The
/// distinction is what keeps the Esc-cancel unblock honest: merely VISITING a blocked pane sends a
/// focus-in report, and that must NOT read as "the user is handling the dialog".
final class PaneInputClassifierTests: XCTestCase {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }
    private let esc = "\u{1B}"

    // MARK: Keystrokes (must count)

    func testPlainKeysCount() {
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("y")))
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("1")))
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\r")), "Enter answers a dialog")
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\u{03}")), "ctrl-C is a deliberate key")
    }

    func testLoneEscIsTheEscKey() {
        // The legacy encoding of the Esc KEY is a bare 0x1B chunk — the exact byte that cancels a
        // permission dialog. It must never be mistaken for a truncated report.
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(Data([0x1B])))
    }

    func testKittyEncodedKeysCount() {
        // Claude Code enables the kitty keyboard protocol: Esc = CSI 27 u, Enter = CSI 13 u.
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[27u")))
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[27;1u")))
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[13u")))
    }

    func testNavigationKeysCount() {
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[A")), "arrow up")
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[Z")), "shift-tab")
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[1;5B")), "modified arrow")
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[3~")), "tilde key (Delete)")
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)OP")), "SS3 F1")
    }

    func testAltChordCounts() {
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)f")), "alt-f word-forward")
    }

    // MARK: Automatic terminal reports (must NOT count)

    func testFocusReportsDoNotCount() {
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[I")), "focus-in = a visit, not a key")
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[O")), "focus-out")
    }

    func testDeviceReportsDoNotCount() {
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[12;40R")), "CPR cursor report")
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[?12;40;1R")), "DECXCPR")
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[?62;22c")), "DA1 reply")
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[>1;10;0c")), "DA2 reply")
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[0n")), "DSR ok reply")
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[?2026;1$y")), "DECRPM reply")
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[?1u")), "kitty flags reply")
    }

    func testStringReportsDoNotCount() {
        XCTAssertFalse(
            PaneInputClassifier.containsUserKeystroke(bytes("\(esc)]11;rgb:1e1e/1e1e/1e1e\u{07}")),
            "OSC colour reply (BEL-terminated)",
        )
        XCTAssertFalse(
            PaneInputClassifier.containsUserKeystroke(bytes("\(esc)P1+r544e\(esc)\\")),
            "DCS XTGETTCAP reply (ST-terminated)",
        )
    }

    func testMouseWheelDoesNotCount() {
        // SGR mouse: scrolling a blocked pane's transcript is reading, not answering.
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[<64;10;10M")))
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[<0;10;10m")))
    }

    // MARK: Mixed / hostile chunks (validate-then-drop)

    func testEmptyChunkDoesNotCount() {
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(Data()))
    }

    func testTruncatedReportDoesNotCount() {
        // A CSI split mid-parameters at a chunk boundary: unknowable → conservative no.
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[12")))
    }

    func testKeystrokeAmidReportsCounts() {
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[I\r")), "focus-in then Enter")
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[12;40R\(esc)[A")), "CPR then arrow")
    }

    func testReportOnlyBurstDoesNotCount() {
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[I\(esc)[0n\(esc)[?62c")))
    }

    // MARK: X10 mouse (the hover-rings-the-cue regression, user-reported 2026-08-10)

    /// The X10/UTF-8 mouse encoding has no private marker and puts its three POSITION bytes BEHIND
    /// the final `M`. Both halves used to break the scan: the final byte read as a keystroke, and
    /// the trailing bytes re-entered the loop as raw text. Merely HOVERING a blocked pane sends a
    /// stream of these (motion reporting), which unblocked the pane on every pointer move and let
    /// the still-visible dialog re-raise it — one awaiting-input cue per mouse movement.
    func testX10MouseDoesNotCount() {
        // `CSI M` + Cb/Cx/Cy = (32, 33, 33): button 0 press at column 1, row 1.
        let press = Data([0x1B, 0x5B, 0x4D, 32, 33, 33])
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(press), "X10 mouse press")
        // The position bytes must be CONSUMED, not left to be read as text: a report-only burst of
        // two motion events in one write still classifies as no key.
        let motion = press + Data([0x1B, 0x5B, 0x4D, 35, 40, 45])
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(motion), "two X10 events in one chunk")
        // …and a real key AFTER the mouse bytes still lands (the scan resumes at the right offset).
        XCTAssertTrue(PaneInputClassifier.containsUserKeystroke(press + bytes("y")), "key after X10 mouse")
    }

    /// urxvt (1015) mouse — parameterised `CSI Cb;Cx;Cy M`, position IN the parameters, so nothing
    /// trails the final byte. Still a report.
    func testUrxvtMouseDoesNotCount() {
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[32;10;10M")))
    }

    /// XTWINOPS geometry answers (`CSI 8;24;80t`) are the emulator replying about its own size.
    func testWindowGeometryReportDoesNotCount() {
        XCTAssertFalse(PaneInputClassifier.containsUserKeystroke(bytes("\(esc)[8;24;80t")))
    }

    // MARK: Cancel-only predicate (what may actually demote a block)

    func testCancelRecognisesEveryEscEncoding() {
        XCTAssertTrue(PaneInputClassifier.containsCancelKeystroke(Data([0x1B])), "bare legacy Esc")
        XCTAssertTrue(PaneInputClassifier.containsCancelKeystroke(Data([0x1B, 0x1B])), "ESC ESC")
        XCTAssertTrue(PaneInputClassifier.containsCancelKeystroke(bytes("\(esc)[27u")), "kitty Esc")
        XCTAssertTrue(PaneInputClassifier.containsCancelKeystroke(bytes("\(esc)[27;1u")), "kitty Esc + mods")
        XCTAssertTrue(PaneInputClassifier.containsCancelKeystroke(Data([0x03])), "ctrl-C")
    }

    /// The narrowing itself: navigating an `AskUserQuestion`'s options, or typing an answer, is NOT
    /// a cancel. Each of these used to demote the block and let the dialog re-raise it, re-ringing
    /// the cue once per keypress.
    func testOrdinaryKeysAreNotCancels() {
        for chunk in [
            "\(esc)[A",
            "\(esc)[B",
            "\(esc)[Z",
            "\(esc)[1;5B",
            "\(esc)[3~",
            "\(esc)[13u",
            "y",
            "1",
            "\r",
            "\t",
            "\(esc)OP",
            "\(esc)f",
        ] {
            XCTAssertTrue(
                PaneInputClassifier.containsUserKeystroke(bytes(chunk)), "\(chunk.debugDescription) is a key",
            )
            XCTAssertFalse(
                PaneInputClassifier.containsCancelKeystroke(bytes(chunk)),
                "\(chunk.debugDescription) must not unblock",
            )
        }
    }

    /// A chunk that BATCHES a navigation key and an Esc into one write must still read as a cancel —
    /// the scan steps over the arrow instead of answering on it.
    func testCancelFoundBehindANavigationKey() {
        XCTAssertTrue(PaneInputClassifier.containsCancelKeystroke(bytes("\(esc)[A\(esc)[27u")))
        XCTAssertTrue(PaneInputClassifier.containsCancelKeystroke(bytes("abc\u{03}")))
    }

    func testReportsAreNeverCancels() {
        XCTAssertFalse(PaneInputClassifier.containsCancelKeystroke(bytes("\(esc)[I")), "focus-in")
        XCTAssertFalse(PaneInputClassifier.containsCancelKeystroke(bytes("\(esc)[12;40R")), "CPR")
        XCTAssertFalse(PaneInputClassifier.containsCancelKeystroke(Data([0x1B, 0x5B, 0x4D, 32, 33, 33])), "X10 mouse")
        XCTAssertFalse(PaneInputClassifier.containsCancelKeystroke(Data()), "empty chunk")
    }
}
