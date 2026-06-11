import XCTest
import Foundation
@testable import AislopdeskClaudeCode

/// WF-7 input-box state-machine tests (A shell / B1 TUI-compose).
final class InputBoxModelTests: XCTestCase {

    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"

    func testDefaultsToShellCommandAffordance() {
        let m = InputBoxModel()
        XCTAssertEqual(m.affordance, .shellCommand)
        XCTAssertEqual(m.mode, .shellPrompt)
    }

    func testShellPromptStaysAModeAfterOSC133AB() {
        let m = InputBoxModel()
        m.ingestOutput(Array("\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)".utf8))
        XCTAssertEqual(m.affordance, .shellCommand)
        XCTAssertEqual(m.mode, .shellPrompt)
    }

    func testAltScreenEnterSwitchesToB1Compose() {
        let m = InputBoxModel()
        m.ingestOutput(Array("\(ESC)[?1049h".utf8))
        XCTAssertEqual(m.affordance, .tuiCompose)
        XCTAssertEqual(m.mode, .altScreen)
    }

    func testAltScreenExitSwitchesBackToA() {
        let m = InputBoxModel()
        m.ingestOutput(Array("\(ESC)[?1049h".utf8))
        XCTAssertEqual(m.affordance, .tuiCompose)
        m.ingestOutput(Array("\(ESC)[?1049l".utf8))
        XCTAssertEqual(m.affordance, .shellCommand)
    }

    func testCommandRunningStateTrackedFromOSC133CD() {
        let m = InputBoxModel()
        m.ingestOutput(Array("\(ESC)]133;A\(BEL)\(ESC)]133;B\(BEL)".utf8))
        XCTAssertFalse(m.commandRunning)
        m.ingestOutput(Array("\(ESC)]133;C\(BEL)".utf8))
        XCTAssertTrue(m.commandRunning)
        m.ingestOutput(Array("\(ESC)]133;D;0\(BEL)".utf8))
        XCTAssertFalse(m.commandRunning)
        XCTAssertEqual(m.lastExitCode, 0)
    }

    func testEventSinkObservesTrackerEvents() {
        let m = InputBoxModel()
        var seen: [TerminalModeEvent] = []
        m.onEvent = { seen.append($0) }
        m.ingestOutput(Array("\(ESC)]133;A\(BEL)\(ESC)[?1049h".utf8))
        XCTAssertEqual(seen, [.promptStart, .enteredAltScreen])
    }

    // MARK: Dedup is active ONLY in B1 compose mode

    func testEchoDedupAppliedInB1ComposeMode() {
        let m = InputBoxModel()
        // Enter alt-screen (TUI compose).
        m.ingestOutput(Array("\(ESC)[?1049h".utf8))
        XCTAssertEqual(m.affordance, .tuiCompose)
        // Compose-box sends a prompt; record it.
        m.recordComposeSent(Array("fix the bug".utf8))
        // The PTY echoes it back; the model must suppress the echo.
        let rendered = m.ingestOutput(Array("fix the bug".utf8))
        XCTAssertTrue(rendered.isEmpty, "echo should be deduped in B1 mode")
    }

    func testEchoNotDedupedInShellAMode() {
        let m = InputBoxModel()
        // In shell-A mode the echo is meant to show; recordComposeSent is a no-op and
        // output passes through untouched.
        m.recordComposeSent(Array("ls".utf8))
        let rendered = m.ingestOutput(Array("ls".utf8))
        XCTAssertEqual(String(decoding: rendered, as: UTF8.self), "ls")
    }

    func testModeFlipResetsDedupState() {
        let m = InputBoxModel()
        m.ingestOutput(Array("\(ESC)[?1049h".utf8)) // B1
        m.recordComposeSent(Array("partial".utf8))
        // Flip back to shell before the echo arrives — dedup state must be reset so a
        // stale "partial" echo cannot suppress real shell output later.
        m.ingestOutput(Array("\(ESC)[?1049l".utf8)) // A (resets ring)
        m.ingestOutput(Array("\(ESC)[?1049h".utf8)) // back to B1
        let rendered = m.ingestOutput(Array("partial".utf8))
        // The earlier record was cleared on the flip, so this is NOT suppressed.
        XCTAssertEqual(String(decoding: rendered, as: UTF8.self), "partial")
    }

    // MARK: Full lifecycle transition trace

    func testFullTransitionTrace() {
        let m = InputBoxModel()
        var affordances: [InputAffordance] = [m.affordance]
        let trace = TerminalModeStreamTrace()

        // shell prompt → run claude → claude enters fullscreen → exits → back at prompt
        for chunk in [
            "\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)",
            "claude\n\(ESC)]133;C\(BEL)",
            "\(ESC)[?1049h",   // fullscreen
            "drawing...",
            "\(ESC)[?1049l",   // exit fullscreen
            "\(ESC)]133;D;0\(BEL)",
        ] {
            m.ingestOutput(Array(chunk.utf8))
            affordances.append(m.affordance)
            trace.note(m.affordance)
        }
        // Affordance went A → ... → B1 (on 1049h) → ... → A (on 1049l) → A.
        XCTAssertTrue(affordances.contains(.tuiCompose))
        XCTAssertEqual(affordances.last, .shellCommand)
        XCTAssertEqual(m.lastExitCode, 0)
    }

    /// Trivial helper to record an affordance trace without adding noise above.
    private final class TerminalModeStreamTrace {
        private(set) var values: [InputAffordance] = []
        func note(_ a: InputAffordance) { values.append(a) }
    }
}
