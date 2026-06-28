import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins WI-5 of E16 (machine half): the pure ``RecipeReplayMachine``. It sequences a recipe's captured
/// commands per the four ``RecipeReplayMode``s (Auto runs all, Ask-Once shows-then-one-Enter, Manually one
/// per Enter, Skip nothing) and PAUSES after an interactive command (via ``InteractiveCommandMatcher``)
/// until the prompt returns or the user continues. Revert-to-confirm-fail: a matcher that never matches does
/// NOT pause after `ssh`. Fully headless.
final class RecipeReplayMachineTests: XCTestCase {
    // MARK: - Skip

    func testSkipInjectsNothing() {
        var machine = RecipeReplayMachine(mode: .skip, commands: ["echo a", "echo b"])
        XCTAssertEqual(machine.start(), [], "Skip injects nothing on start")
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.confirm(), [], "Skip ignores Enter")
        XCTAssertEqual(machine.noteReturnedToPrompt(), [])
        XCTAssertEqual(machine.injected, [])
    }

    // MARK: - Auto

    func testAutoRunsAllInSequence() {
        var machine = RecipeReplayMachine(mode: .auto, commands: ["echo a", "echo b", "echo c"])
        XCTAssertEqual(machine.start(), ["echo a", "echo b", "echo c"], "Auto injects the whole queue in order")
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.injected, ["echo a", "echo b", "echo c"])
        XCTAssertTrue(machine.isFinished)
    }

    func testAutoEmptyQueueFinishesImmediately() {
        var machine = RecipeReplayMachine(mode: .auto, commands: [])
        XCTAssertEqual(machine.start(), [])
        XCTAssertEqual(machine.state, .finished)
    }

    // MARK: - Ask Once

    func testAskOnceShowsThenOneEnterRunsAll() {
        var machine = RecipeReplayMachine(mode: .askOnce, commands: ["echo a", "echo b"])
        XCTAssertEqual(machine.start(), [], "Ask-Once injects nothing until confirmed")
        XCTAssertEqual(machine.state, .awaitingConfirmation)
        XCTAssertEqual(machine.confirm(), ["echo a", "echo b"], "one Enter runs all")
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.confirm(), [], "a second Enter does nothing")
    }

    // MARK: - Manually

    func testManuallyFeedsOnePerEnter() {
        var machine = RecipeReplayMachine(mode: .manually, commands: ["echo a", "echo b", "echo c"])
        XCTAssertEqual(machine.start(), [])
        XCTAssertEqual(machine.state, .awaitingConfirmation)
        XCTAssertEqual(machine.confirm(), ["echo a"], "one command per Enter")
        XCTAssertEqual(machine.state, .awaitingConfirmation)
        XCTAssertEqual(machine.confirm(), ["echo b"])
        XCTAssertEqual(machine.confirm(), ["echo c"])
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.confirm(), [], "no commands left")
        XCTAssertEqual(machine.injected, ["echo a", "echo b", "echo c"])
    }

    // MARK: - shell-handoff pause (Auto)

    func testAutoPausesAfterInteractiveUntilPromptReturns() {
        var machine = RecipeReplayMachine(mode: .auto, commands: ["echo a", "ssh host", "echo b"])
        // Auto injects up to AND INCLUDING the interactive command, then pauses — `echo b` is held back.
        XCTAssertEqual(machine.start(), ["echo a", "ssh host"])
        XCTAssertEqual(machine.state, .paused(.interactiveCommand("ssh host")))
        XCTAssertEqual(machine.injected, ["echo a", "ssh host"], "the post-ssh command is NOT yet injected")
        XCTAssertFalse(machine.isFinished)
        // The local shell returns to a prompt → the queue resumes.
        XCTAssertEqual(machine.noteReturnedToPrompt(), ["echo b"])
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.injected, ["echo a", "ssh host", "echo b"])
    }

    func testManualContinueResumesAfterHandoff() {
        var machine = RecipeReplayMachine(mode: .auto, commands: ["ssh host", "echo done"])
        XCTAssertEqual(machine.start(), ["ssh host"], "pauses immediately after the leading interactive command")
        XCTAssertEqual(machine.state, .paused(.interactiveCommand("ssh host")))
        // A manual continue (Enter) resumes just like a prompt-return.
        XCTAssertEqual(machine.confirm(), ["echo done"])
        XCTAssertEqual(machine.state, .finished)
    }

    func testTwoInteractiveCommandsPauseTwice() {
        var machine = RecipeReplayMachine(mode: .auto, commands: ["ssh a", "ssh b"])
        XCTAssertEqual(machine.start(), ["ssh a"])
        XCTAssertEqual(machine.state, .paused(.interactiveCommand("ssh a")))
        XCTAssertEqual(machine.noteReturnedToPrompt(), ["ssh b"], "resume injects the next interactive command")
        XCTAssertEqual(machine.state, .paused(.interactiveCommand("ssh b")))
        XCTAssertEqual(machine.noteReturnedToPrompt(), [], "nothing left after the final command")
        XCTAssertEqual(machine.state, .finished)
    }

    // MARK: - shell-handoff pause (Ask Once)

    func testAskOnceAlsoPausesAfterInteractive() {
        var machine = RecipeReplayMachine(mode: .askOnce, commands: ["echo a", "ssh host", "echo b"])
        XCTAssertEqual(machine.start(), [])
        XCTAssertEqual(machine.confirm(), ["echo a", "ssh host"], "the one Enter runs up to the handoff")
        XCTAssertEqual(machine.state, .paused(.interactiveCommand("ssh host")))
        XCTAssertEqual(machine.noteReturnedToPrompt(), ["echo b"])
        XCTAssertEqual(machine.state, .finished)
    }

    // MARK: - noteReturnedToPrompt is a no-op when not paused for a handoff

    func testPromptReturnIsNoOpWhenNotPaused() {
        var machine = RecipeReplayMachine(mode: .auto, commands: ["echo a"])
        XCTAssertEqual(machine.start(), ["echo a"])
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.noteReturnedToPrompt(), [], "a finished machine ignores prompt-returns")
    }

    func testPromptReturnDoesNotResumeAManualPause() {
        var machine = RecipeReplayMachine(mode: .askOnce, commands: ["echo a", "echo b"])
        _ = machine.start()
        machine.pause(reason: .manual)
        XCTAssertEqual(machine.state, .paused(.manual))
        // A prompt-return must NOT resume a deliberate manual pause — only a manual continue does.
        XCTAssertEqual(machine.noteReturnedToPrompt(), [])
        XCTAssertEqual(machine.state, .paused(.manual))
        XCTAssertEqual(machine.confirm(), ["echo a", "echo b"], "confirm is the manual continue")
        XCTAssertEqual(machine.state, .finished)
    }

    // MARK: - revert-to-confirm-fail: the pause DEPENDS on the matcher

    func testNoPauseWhenMatcherNeverMatches() {
        // With a matcher that recognizes NOTHING as interactive, Auto runs straight through `ssh` — proving
        // the post-ssh pause is driven by InteractiveCommandMatcher, not an unconditional behavior.
        let inert = InteractiveCommandMatcher(interactivePrograms: [], subcommandRules: [])
        var machine = RecipeReplayMachine(mode: .auto, commands: ["echo a", "ssh host", "echo b"], matcher: inert)
        XCTAssertEqual(machine.start(), ["echo a", "ssh host", "echo b"], "no matcher → no handoff pause")
        XCTAssertEqual(machine.state, .finished)
    }

    // MARK: - pendingCommands reflects progress

    func testPendingCommandsReflectsProgress() {
        var machine = RecipeReplayMachine(mode: .manually, commands: ["a", "b", "c"])
        _ = machine.start()
        XCTAssertEqual(machine.pendingCommands, ["a", "b", "c"])
        _ = machine.confirm()
        XCTAssertEqual(machine.pendingCommands, ["b", "c"])
        _ = machine.confirm()
        _ = machine.confirm()
        XCTAssertEqual(machine.pendingCommands, [])
    }
}
