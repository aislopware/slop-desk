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

    /// Tab, then Enter before the host answers — the fastest thing a user does with a completion they
    /// decided not to wait for.
    ///
    /// The answer is for a line that has RUN. Landing it on the fresh prompt would open a panel over
    /// a line the user has not started, and the next Enter would accept a candidate instead of
    /// running what they typed — the completion eating a command.
    func testAnAnswerForALineThatHasRunIsDropped() async {
        let model = seeded()
        model.shellCompletionSink = { _, _ in .groups(Data()) }

        model.completeCommandPrompt(forward: true)
        XCTAssertTrue(model.submitCommandPrompt(), "the line ran")
        await drainReply()

        XCTAssertEqual(model.commandPrompt.text, "", "the fresh prompt is still empty")
        XCTAssertTrue(model.commandPrompt.candidates.isEmpty, "and carries no panel from the last line")
    }

    /// ⌃C is the other way a line ends. It reaches ``CommandPrompt/clear()`` straight from the two
    /// views, so the epoch is bumped THERE rather than at a call site that could forget.
    func testAnAnswerForAnAbandonedLineIsDropped() async {
        let model = seeded()
        model.shellCompletionSink = { _, _ in .groups(Data()) }

        model.completeCommandPrompt(forward: true)
        model.commandPrompt.clear()
        await drainReply()

        XCTAssertEqual(model.commandPrompt.text, "", "⌃C abandoned it")
        XCTAssertTrue(model.commandPrompt.candidates.isEmpty, "so the answer had nothing to land on")
    }

    /// Escape during the round trip. The panel the user dismissed must not come back wearing the
    /// shell's answer — a list that reappears sixty milliseconds after ⎋ reads as a bug, and Tab is
    /// right there to ask again.
    func testAnAnswerForADismissedPanelIsDropped() async {
        let model = seeded()
        model.shellCompletionSink = { _, _ in .groups(Data()) }

        model.completeCommandPrompt(forward: true)
        model.commandPrompt.dismissCompletion()
        await drainReply()

        XCTAssertTrue(model.commandPrompt.candidates.isEmpty, "⎋ won")
        XCTAssertEqual(model.commandPrompt.text, "ls", "and nothing was accepted into the line")
    }

    /// The submit that does NOT end a line: an open quote makes Enter a newline, and the question is
    /// still about the line on screen.
    func testAnOpenDocumentDoesNotRetireTheQuestion() async {
        let model = TerminalViewModel()
        model.commandPrompt.recordHistory("echo \"hi there\"")
        model.commandPrompt.insert("echo \"hi")
        model.shellCompletionSink = { _, _ in .groups(Data()) }

        model.completeCommandPrompt(forward: true)
        XCTAssertFalse(model.submitCommandPrompt(), "the quote is still open, so Enter added a row")
        await drainReply()

        XCTAssertEqual(model.commandPrompt.candidates.count, 1, "the answer still had its line")
    }

    /// Enter with a panel up is NOT a submit. Both views branch on `candidates` first and call
    /// ``CommandPrompt/acceptCompletion()``, returning without ever reaching
    /// ``TerminalViewModel/submitCommandPrompt()`` — so the accept is a question-ender in its own
    /// right, and a reply landing after it would reopen a panel over a line the user just settled.
    func testAnAnswerForAnAcceptedCandidateIsDropped() async {
        let model = TerminalViewModel()
        // The accepted line is itself a PREFIX of another entry, which is what makes the reply's
        // `complete()` find something to reopen the panel with.
        model.commandPrompt.recordHistory("ls -la --color=auto")
        model.commandPrompt.recordHistory("ls -la")
        model.commandPrompt.insert("ls")
        model.shellCompletionSink = { _, _ in .groups(Data()) }

        model.completeCommandPrompt(forward: true)
        XCTAssertEqual(model.commandPrompt.candidates.count, 2, "the local candidates are up")
        XCTAssertTrue(model.commandPrompt.acceptCompletion(), "Enter takes one, the way both views do")
        XCTAssertEqual(model.commandPrompt.text, "ls -la", "the highlighted one")
        await drainReply()

        XCTAssertTrue(model.commandPrompt.candidates.isEmpty, "with no panel back over it")
    }

    /// ⌃R during the round trip. A search's rows ARE `candidates`, so a completion reply that merged
    /// would drop shell candidates into a reverse search — a list of two different things.
    func testAnAnswerDoesNotMergeIntoAnOpenReverseSearch() async {
        let model = seeded()
        model.shellCompletionSink = { _, _ in .groups(Data()) }

        model.completeCommandPrompt(forward: true)
        model.commandPrompt.beginSearch()
        await drainReply()

        XCTAssertTrue(model.commandPrompt.isSearching, "the search owns the panel")
        XCTAssertEqual(model.commandPrompt.text, "ls", "and nothing was completed into the draft")
    }

    /// Lets the `Task` the ask spawned run to completion. Yielding rather than sleeping: the sink
    /// answers immediately in every test that calls this, so there is nothing to wait OUT.
    private func drainReply() async {
        for _ in 0..<4 { await Task.yield() }
    }
}
