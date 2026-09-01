import XCTest
@testable import SlopDeskWorkspaceCore

/// Tab against the HOST's own zsh — `docs/68` §11's client half.
///
/// The differentiator this whole verb exists for is that the candidates come from the user's REAL
/// completion functions rather than a spec database shipped in the app, and a differentiator that no
/// keystroke reaches is worth nothing. So what is pinned here is that the key ASKS, that the answer
/// is allowed to arrive late without rewriting the line under the user, and that a host which cannot
/// answer is asked exactly once.
///
/// The sink is a closure, so none of this needs a socket, a host, or a zsh.
@MainActor
final class TerminalShellCompletionTests: XCTestCase {
    /// A model with one history entry, so the LOCAL sources have exactly one candidate for `ls`.
    ///
    /// One is the interesting number: it is the count that triggers the outright accept, and so the
    /// count that would let a local guess win a race against the shell.
    private func seeded() -> TerminalViewModel {
        let model = TerminalViewModel()
        model.commandPrompt.recordHistory("ls -la")
        model.commandPrompt.insert("ls")
        return model
    }

    func testTabAsksTheHostShell() async {
        let model = seeded()
        var asked: [(Int, String)] = []
        model.shellCompletionSink = { cursor, buffer in
            asked.append((cursor, buffer))
            return .groups(Data())
        }

        model.completeCommandPrompt(forward: true)
        await Task.yield()

        XCTAssertEqual(asked.count, 1, "Tab asks the user's own shell")
        XCTAssertEqual(asked.first?.0, 2, "the caret is sent in CHARACTERS")
        XCTAssertEqual(asked.first?.1, "ls", "and the whole line the shell must lex")
    }

    /// The race the suppression exists for: one LOCAL candidate must not be accepted while the shell
    /// is still speaking, because the shell's answer may hold twenty more.
    func testALoneLocalCandidateIsNotAcceptedWhileTheShellIsStillAnswering() {
        let model = seeded()
        model.shellCompletionSink = { _, _ in
            // Never answers within this test — which is what a 400 ms host deadline looks like from
            // here, and the state the user's line has to survive.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .notReady
        }

        model.completeCommandPrompt(forward: true)

        XCTAssertEqual(model.commandPrompt.text, "ls", "the line is untouched while the shell is out")
        XCTAssertEqual(model.commandPrompt.candidates.count, 1, "but the local candidate IS on screen")
    }

    /// With no host to ask, the rule is the one every shell has: one candidate applies outright.
    func testWithNoSinkTheLoneCandidateStillAppliesOutright() {
        let model = seeded()
        model.completeCommandPrompt(forward: true)
        XCTAssertEqual(model.commandPrompt.text, "ls -la", "no shell to wait for, so Tab completes")
    }

    /// The accept moves to the reply, where the whole list is finally known.
    func testTheReplyAppliesTheAcceptOnceTheListIsWhole() async {
        let model = seeded()
        model.shellCompletionSink = { _, _ in .groups(Data()) }
        var redrawn = 0

        model.completeCommandPrompt(forward: true) { redrawn += 1 }
        XCTAssertEqual(model.commandPrompt.text, "ls", "not yet — the shell has not answered")

        await drainReply()
        XCTAssertEqual(model.commandPrompt.text, "ls -la", "the merged list had one candidate")
        XCTAssertEqual(redrawn, 1, "and the band is told, since the key handler has long returned")
    }

    /// The user types through the round trip. Merging is safe — the Rust provider re-derives its
    /// range against the live document — but ACCEPTING into a line that moved would write over what
    /// they were in the middle of saying.
    func testAnAnswerThatArrivesAfterTheLineMovedDoesNotAcceptIntoIt() async {
        let model = seeded()
        model.shellCompletionSink = { _, _ in .groups(Data()) }

        model.completeCommandPrompt(forward: true)
        model.commandPrompt.insert("x") // the keystroke that outran the host
        await drainReply()

        XCTAssertEqual(model.commandPrompt.text, "lsx", "the answer was for a line that is gone")
    }

    /// `.noShell` is the permanent refusal, and paying the round trip again on every Tab for the rest
    /// of the connection is exactly what the host spends a second status to prevent.
    func testAHostWithoutZshIsAskedExactlyOnce() async {
        let model = seeded()
        var asks = 0
        model.shellCompletionSink = { _, _ in
            asks += 1
            return .noShell
        }

        model.completeCommandPrompt(forward: true)
        await drainReply()
        XCTAssertFalse(model.shellCompletionAvailable, "the latch is down")

        model.commandPrompt.dismissCompletion()
        model.completeCommandPrompt(forward: true)
        await drainReply()
        XCTAssertEqual(asks, 1, "and the second Tab does not ask again")
    }

    /// `.notReady` is the TRANSIENT one — a warming shell must not be abandoned for it.
    func testAWarmingShellIsAskedAgain() async {
        let model = seeded()
        var asks = 0
        model.shellCompletionSink = { _, _ in
            asks += 1
            return .notReady
        }

        model.completeCommandPrompt(forward: true)
        await drainReply()
        model.commandPrompt.dismissCompletion()
        model.completeCommandPrompt(forward: true)
        await drainReply()

        XCTAssertEqual(asks, 2, "still warming is not the same as not zsh")
        XCTAssertTrue(model.shellCompletionAvailable)
    }

    /// Two Tabs in flight, answered out of order: the OLDER answer must not land.
    func testAStaleAnswerIsDropped() async {
        let model = seeded()
        var applied = 0
        model.shellCompletionSink = { _, _ in
            applied += 1
            return .groups(Data())
        }

        model.completeCommandPrompt(forward: true)
        // A second ask before the first has been drained — the panel is dismissed first so the Tab
        // is a fresh completion rather than a walk through the list already up.
        model.commandPrompt.dismissCompletion()
        model.completeCommandPrompt(forward: true)
        await drainReply()

        XCTAssertEqual(applied, 2, "both requests went out")
        XCTAssertEqual(model.commandPrompt.text, "ls -la", "and the LIVE one is what landed")
    }

    /// Tab with a list already up walks it and asks nobody — the caret has not moved, so the answer
    /// would be to a question already answered.
    func testASecondTabWalksTheListWithoutAskingAgain() async {
        let model = seeded()
        model.commandPrompt.recordHistory("ls -lh")
        var asks = 0
        model.shellCompletionSink = { _, _ in
            asks += 1
            return .notReady
        }

        model.completeCommandPrompt(forward: true)
        await drainReply()
        XCTAssertEqual(model.commandPrompt.candidates.count, 2, "two history entries match `ls`")

        model.completeCommandPrompt(forward: true)
        await drainReply()
        XCTAssertEqual(asks, 1, "the second Tab moves the highlight; it does not re-ask")
        XCTAssertEqual(model.commandPrompt.selectedCandidate, 1, "and the highlight moved")
    }

    /// Lets the `Task` the ask spawned run to completion. Yielding rather than sleeping: the sink
    /// answers immediately in every test that calls this, so there is nothing to wait OUT.
    private func drainReply() async {
        for _ in 0..<4 { await Task.yield() }
    }
}
