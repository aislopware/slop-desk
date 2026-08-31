import SlopDeskClaudeCode
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests the `@MainActor @Observable` ``InputBarModel`` shell — it must faithfully mirror the
/// `SlopDeskClaudeCode.InputBoxModel` affordance (A shell / B1 TUI-compose) and drive the dedup
/// ring only in B1. The byte-level logic is `SlopDeskClaudeCode`'s; here we assert the wiring +
/// submit encoding.
@MainActor
final class InputBarModelTests: XCTestCase {
    /// `ESC[?1049h` = enter alt-screen (→ B1); `ESC[?1049l` = leave (→ A).
    private let enterAlt = Data([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68])
    private let leaveAlt = Data([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C])

    func testStartsInShellAffordance() {
        let model = InputBarModel()
        XCTAssertEqual(model.affordance, .shellCommand)
    }

    func testAffordanceFlipsToB1OnAltScreen() {
        let model = InputBarModel()
        model.ingestOutput(enterAlt)
        XCTAssertEqual(model.affordance, .tuiCompose)
        model.ingestOutput(leaveAlt)
        XCTAssertEqual(model.affordance, .shellCommand)
    }

    /// ⚠️ THE COMPOSE FIELD IS GONE — `TerminalViewModel.commandPrompt` holds the line now
    /// (`docs/68` §5.4), so what was asserted here as "encodeSubmit appends CR" is asserted on the
    /// editor's submit instead. What is still this model's, and still worth pinning, is the ECHO
    /// DEDUP: which affordance records what it sends.
    func testB1RecordsWhatItSendsAndShellDoesNot() {
        // In B1 the ring holds the bytes, so the PTY's echo of them renders as nothing.
        let model = InputBarModel()
        model.ingestOutput(enterAlt) // → B1
        model.sendText("hi\r")
        XCTAssertEqual(
            model.ingestOutput(Data("hi\r\n".utf8)),
            Data(),
            "B1 dedup ring suppresses the recorded echo",
        )

        // In A (shell) the same send must NOT record — the echo is what draws the command line.
        let shellModel = InputBarModel() // starts in A
        shellModel.sendText("hi\r")
        XCTAssertEqual(
            shellModel.ingestOutput(Data("hi\r\n".utf8)),
            Data("hi\r\n".utf8),
            "A mode shows echo (ring bypassed)",
        )
    }

    /// A CONTROL send is never recorded, in either affordance: the PTY does not echo an arrow, and a
    /// recorded one would sit in the ring waiting to swallow a real `CUF` from a redrawing TUI.
    func testControlSendsAreNeverRecorded() {
        let model = InputBarModel()
        model.ingestOutput(enterAlt) // → B1
        model.sendRaw([0x1B, 0x5B, 0x43]) // ESC [ C
        XCTAssertEqual(
            model.ingestOutput(Data([0x1B, 0x5B, 0x43])),
            Data([0x1B, 0x5B, 0x43]),
            "a real CUF from the program still renders",
        )
    }

    func testCommandRunningTracked() {
        let model = InputBarModel()
        // OSC 133;C = command output begins; ;D;0 = finished exit 0.
        let cmdStart = Data("\u{1B}]133;C\u{07}".utf8)
        let cmdDone = Data("\u{1B}]133;D;0\u{07}".utf8)
        model.ingestOutput(cmdStart)
        XCTAssertTrue(model.commandRunning)
        model.ingestOutput(cmdDone)
        XCTAssertFalse(model.commandRunning)
        XCTAssertEqual(model.lastExitCode, 0)
    }
}
