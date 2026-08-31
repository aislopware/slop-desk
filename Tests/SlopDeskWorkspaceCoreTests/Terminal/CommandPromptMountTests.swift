import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The MOUNT, not the editor: `slopdesk_terminal::prompt` has its own 4 500 lines of tests for what
/// a word motion or an undo step is. What is pinned here is the three things that only exist because
/// the editor is now wired to a pane — when it owns the keyboard, what a submitted line becomes on
/// the wire, and which control keys it may not have.
@MainActor
final class CommandPromptMountTests: XCTestCase {
    /// A model at an idle shell prompt on a live connection — the one state the editor arms in.
    private func makeLiveModel() -> TerminalViewModel {
        let model = TerminalViewModel()
        model.markReconnecting()
        model.ingestOutput(Data("$ ".utf8)) // first byte flips reconnecting → connected
        return model
    }

    // MARK: Arming

    func testTheEditorArmsAtAnIdlePromptOnALiveConnection() {
        XCTAssertTrue(makeLiveModel().commandPromptArmed)
    }

    /// Revert-to-confirm-fail for the connection term: a model that never connected must not claim
    /// the keyboard, or a disconnected pane would swallow every key into an editor whose Enter goes
    /// nowhere.
    func testADisconnectedPaneNeverArms() {
        let model = TerminalViewModel()
        XCTAssertEqual(model.connectionStatus, .idle)
        XCTAssertFalse(model.commandPromptArmed)
    }

    /// The alternate screen is the shell saying the program owns the viewport — `vim`'s `:` line is
    /// not a shell prompt, and an editor that armed over it would eat every keystroke of the file.
    func testAFullScreenProgramTakesTheKeyboardBack() {
        let model = makeLiveModel()
        model.ingestOutput(Data([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68])) // DECSET 1049
        XCTAssertTrue(model.isAlternateScreen)
        XCTAssertFalse(model.commandPromptArmed)
    }

    // MARK: Submit

    /// A closed document goes out as the line plus ONE carriage return, and the editor is empty
    /// afterwards — which is what lets the shell's own echo open the block.
    func testSubmitSendsTheLineAndACarriageReturn() {
        let model = makeLiveModel()
        var sent: [Data] = []
        model.inputSink = { sent.append($0) }
        model.commandPrompt.insert("echo hi")

        XCTAssertTrue(model.submitCommandPrompt())
        XCTAssertEqual(sent, [Data("echo hi\r".utf8)])
        XCTAssertEqual(model.commandPrompt.text, "")
    }

    /// The command reaches the HISTORY as part of submitting, so ↑ finds it on the next line without
    /// anything else having to remember it.
    func testASubmittedCommandIsInTheHistory() {
        let model = makeLiveModel()
        model.inputSink = { _ in }
        model.commandPrompt.insert("git status")
        XCTAssertTrue(model.submitCommandPrompt())
        XCTAssertEqual(model.commandPrompt.history, ["git status"])
    }

    /// An OPEN document sends nothing at all. This is the whole reason Enter is a question rather than
    /// a byte: `echo '` half-typed would otherwise run, and the shell would sit waiting for a quote
    /// with the user's next command going into it.
    func testAnUnclosedQuoteAddsALineInsteadOfRunning() {
        let model = makeLiveModel()
        var sent: [Data] = []
        model.inputSink = { sent.append($0) }
        model.commandPrompt.insert("echo 'hi")

        XCTAssertFalse(model.submitCommandPrompt())
        XCTAssertEqual(sent, [], "nothing may reach the shell while the document is open")
        XCTAssertEqual(model.commandPrompt.unterminated, .singleQuote)
        XCTAssertEqual(model.commandPrompt.text, "echo 'hi\n")
    }

    /// A multi-line command that IS closed goes out with its newlines intact — a shell reads a
    /// compound exactly this way, so nothing has to be escaped or bracketed on the way.
    func testAClosedCompoundKeepsItsNewlines() {
        let model = makeLiveModel()
        var sent: [Data] = []
        model.inputSink = { sent.append($0) }
        model.commandPrompt.insert("for x in 1 2; do")
        model.commandPrompt.insertNewline()
        model.commandPrompt.insert("echo $x; done")

        XCTAssertTrue(model.submitCommandPrompt())
        XCTAssertEqual(sent, [Data("for x in 1 2; do\necho $x; done\r".utf8)])
    }

    /// A read-only pane drops the bytes at ``TerminalViewModel/sendInput(_:)``, which is the single
    /// outbound gate — so the editor riding that door inherits the lock rather than needing its own.
    func testAReadOnlyPaneSendsNothing() {
        let model = makeLiveModel()
        var sent: [Data] = []
        model.inputSink = { sent.append($0) }
        model.isReadOnly = true
        model.commandPrompt.insert("rm -rf /")

        XCTAssertTrue(model.submitCommandPrompt(), "the editor still consumed the key")
        XCTAssertEqual(sent, [], "but the lock is what decides whether bytes leave")
    }

    // MARK: The control keys the editor may not have

    func testCtrlCAbandonsTheLineAndCtrlDIsEofOnlyWhenEmpty() {
        XCTAssertEqual(PromptControlAction.of(letter: "c", bufferEmpty: false), .forwardAndClear)
        XCTAssertEqual(PromptControlAction.of(letter: "d", bufferEmpty: true), .forward)
        XCTAssertEqual(PromptControlAction.of(letter: "d", bufferEmpty: false), .editor)
        XCTAssertEqual(PromptControlAction.of(letter: "z", bufferEmpty: false), .forward)
        XCTAssertEqual(PromptControlAction.of(letter: "l", bufferEmpty: false), .forward)
    }

    /// The readline motions the editor now owns. ⌃A reaching a shell that is not doing the editing
    /// would move a cursor nobody can see.
    func testTheLineEditLettersStayWithTheEditor() {
        for letter in ["a", "e", "k", "w", "u", "y", "b", "f", "p", "n"] {
            XCTAssertEqual(PromptControlAction.of(letter: Character(letter), bufferEmpty: false), .editor, letter)
        }
    }

    /// The caller may hand over whatever the platform reported: an uppercase ⇧⌃C is still ⌃C.
    func testTheLetterIsLowercasedOnThisSide() {
        XCTAssertEqual(PromptControlAction.of(letter: "C", bufferEmpty: false), .forwardAndClear)
    }

    /// A non-ASCII letter cannot be a control chord, and must not be read as one by truncation.
    func testANonAsciiLetterIsTheEditors() {
        XCTAssertEqual(PromptControlAction.of(letter: "ć", bufferEmpty: false), .editor)
    }
}
