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
}
