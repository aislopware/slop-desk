import AislopdeskClaudeCode
import XCTest
@testable import AislopdeskClientUI

/// Tests the `@MainActor @Observable` ``InputBarModel`` shell — it must faithfully mirror the
/// `AislopdeskClaudeCode.InputBoxModel` affordance (A shell / B1 TUI-compose) and drive the dedup
/// ring only in B1. The byte-level logic is `AislopdeskClaudeCode`'s; here we assert the wiring +
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

    func testEncodeSubmitAppendsCarriageReturn() {
        let model = InputBarModel()
        model.compose = "ls -la"
        let bytes = model.encodeSubmit()
        XCTAssertEqual(bytes, Data("ls -la\r".utf8))
    }

    func testEncodeSubmitEmptyIsNil() {
        let model = InputBarModel()
        model.compose = ""
        XCTAssertNil(model.encodeSubmit())
    }

    func testB1SubmitRecordsForDedupAndShellDoesNot() throws {
        // In B1, encodeSubmit records the bytes so the echo is suppressed: feeding the echo
        // back through ingestOutput yields nothing to render.
        let model = InputBarModel()
        model.ingestOutput(enterAlt) // → B1
        model.compose = "hi"
        let sent = try XCTUnwrap(model.encodeSubmit()) // records "hi\r" in the ring
        XCTAssertEqual(sent, Data("hi\r".utf8))

        // The PTY echoes "hi\r\n"; the ring should strip the recorded prefix.
        let echo = Data("hi\r\n".utf8)
        let rendered = model.ingestOutput(echo)
        XCTAssertEqual(rendered, Data(), "B1 dedup ring suppresses the recorded echo")

        // In A (shell), the same submit must NOT record (echo shows normally).
        let shellModel = InputBarModel() // starts in A
        shellModel.compose = "hi"
        _ = shellModel.encodeSubmit()
        let shellRendered = shellModel.ingestOutput(Data("hi\r\n".utf8))
        XCTAssertEqual(shellRendered, Data("hi\r\n".utf8), "A mode shows echo (ring bypassed)")
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
