import XCTest
@testable import SlopDeskWorkspaceCore

/// The typo colour against the HOST's own zsh — `docs/68` §11's other client half.
///
/// The claim this verb exists to make is that `gst` is not a typo just because no `PATH` walk finds
/// it: it is the user's plugin alias, and only their shell knows. So what is pinned here is that
/// typing ASKS, that the answer reaches the SPANS the band paints from, that a burst of keystrokes
/// is not a burst of round trips, and that an answer which outlived the command it was asked during
/// cannot repaint the line that came after.
///
/// The sink is a closure, so none of this needs a socket, a host, or a zsh.
@MainActor
final class TerminalWhenceWordsTests: XCTestCase {
    /// One verdict answer, encoded the way `slopdesk-wire`'s `encode_whence` does — `[u16 count]`
    /// then, per entry, `[u16 len][utf8 word][u8 kind]`, big-endian.
    ///
    /// Hand-built rather than round-tripped through the host: the point of the test is that the
    /// client can read what the wire says, and a helper that called the same encoder would only be
    /// asserting the encoder agrees with itself.
    private func verdicts(_ answers: [(String, UInt8)]) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8(answers.count >> 8), UInt8(answers.count & 0xFF)])
        for (word, kind) in answers {
            let utf8 = Array(word.utf8)
            data.append(contentsOf: [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)])
            data.append(contentsOf: utf8)
            data.append(kind)
        }
        return data
    }

    /// The words a request asks about — `[u16 count]` then `[u16 len][utf8 word]` each.
    ///
    /// A fake that answers about the words it was actually ASKED is the only kind that can pin the
    /// re-ask: a fake that always names the same word either answers a question nobody asked or
    /// answers one that was never in flight.
    private func words(of request: Data) -> [String] {
        var bytes = Array(request)
        func short() -> Int {
            let value = Int(bytes[0]) << 8 | Int(bytes[1])
            bytes.removeFirst(2)
            return value
        }
        let count = short()
        return (0..<count).map { _ in
            let length = short()
            let word = String(bytes: bytes.prefix(length), encoding: .utf8) ?? ""
            bytes.removeFirst(length)
            return word
        }
    }

    /// zsh's `whence -w` vocabulary, as the wire numbers it. `none` is the only one that paints.
    private enum Kind {
        static let none: UInt8 = 0
        static let command: UInt8 = 1
        static let alias: UInt8 = 3
    }

    private func typing(_ line: String) -> TerminalViewModel {
        let model = TerminalViewModel()
        model.commandPrompt.insert(line)
        return model
    }

    func testTypingAsksTheHostShellAboutTheCommandWord() async {
        let model = typing("gst")
        var asked = 0
        model.whenceSink = { _ in
            asked += 1
            return .notReady
        }

        model.askShellAboutTypedCommands()
        await drainReply()

        XCTAssertEqual(asked, 1, "a command word with no verdict is a question")
    }

    /// The reach assertion: a `none` verdict must arrive at the span the band reads its ink from.
    func testAWordTheShellCannotFindComesBackAsAnUnknownCommandSpan() async {
        let model = typing("nosuchcmd")
        model.whenceSink = { [verdicts] _ in .groups(verdicts([("nosuchcmd", Kind.none)])) }

        XCTAssertFalse(
            model.commandPrompt.spans.contains { $0.kind == .unknownCommand },
            "nothing is a typo while the answer is in flight",
        )
        model.askShellAboutTypedCommands()
        await drainReply()

        let unknown = model.commandPrompt.spans.filter { $0.kind == .unknownCommand }
        XCTAssertEqual(unknown.count, 1, "the shell said it cannot find it")
    }

    /// The differentiator, stated as a test: an alias is NOT a typo, and no `PATH` walk would agree.
    func testAnAliasIsNotPaintedAsATypo() async {
        let model = typing("gst")
        model.whenceSink = { [verdicts] _ in .groups(verdicts([("gst", Kind.alias)])) }

        model.askShellAboutTypedCommands()
        await drainReply()

        XCTAssertFalse(
            model.commandPrompt.spans.contains { $0.kind == .unknownCommand },
            "the user's plugin defines it, which only their shell knows",
        )
    }

    /// Typing `git` is three keystrokes, and each one calls the hook. Without the in-flight guard
    /// that is three requests carrying `g`, `gi` and `git` — two of them about prefixes the user has
    /// already typed past.
    func testABurstOfKeystrokesIsNotABurstOfRoundTrips() async {
        let model = TerminalViewModel()
        var asked: [[String]] = []
        model.whenceSink = { [verdicts, words] request in
            let asking = words(request)
            asked.append(asking)
            return .groups(verdicts(asking.map { ($0, Kind.command) }))
        }

        for character in "git" {
            model.commandPrompt.insert(String(character))
            model.askShellAboutTypedCommands()
        }
        await drainReply()

        XCTAssertEqual(
            asked,
            [["g"], ["git"]],
            "three keystrokes, two round trips: the one that went out, and one re-ask for what the "
                + "user typed through it — never `gi`, a prefix already left behind",
        )
    }

    /// The re-ask must not be a LOOP. A host that answers a word it was not asked about — or
    /// answers nothing at all — leaves the request unchanged, and a client that re-asked on that
    /// would spin for as long as the pane lived.
    func testAHostThatAnswersNothingIsNotAskedForever() async {
        let model = typing("gst")
        var asks = 0
        model.whenceSink = { [verdicts] _ in
            asks += 1
            return .groups(verdicts([]))
        }

        model.askShellAboutTypedCommands()
        await drainReply()

        XCTAssertEqual(asks, 1, "the question did not change, so the next keystroke owns the retry")
    }

    /// `.noShell` is the permanent refusal, and it is ONE fact about the host: the shell that cannot
    /// answer this cannot complete either, so the completion latch is the latch.
    func testAHostWithoutZshIsAskedExactlyOnce() async {
        let model = typing("gst")
        var asks = 0
        model.whenceSink = { _ in
            asks += 1
            return .noShell
        }

        model.askShellAboutTypedCommands()
        await drainReply()
        XCTAssertFalse(model.shellCompletionAvailable, "the shared latch is down")

        model.commandPrompt.insert("x")
        model.askShellAboutTypedCommands()
        await drainReply()
        XCTAssertEqual(asks, 1, "and the next keystroke does not ask again")
    }

    /// `.notReady` is the TRANSIENT one — the captive shell takes seconds to warm, and a prompt that
    /// gave up on it would never colour anything for the rest of the session.
    func testAWarmingShellIsAskedAgain() async {
        let model = typing("gst")
        var asks = 0
        model.whenceSink = { _ in
            asks += 1
            return .notReady
        }

        model.askShellAboutTypedCommands()
        await drainReply()
        model.commandPrompt.insert("x")
        model.askShellAboutTypedCommands()
        await drainReply()

        XCTAssertEqual(asks, 2, "still warming is not the same as not zsh")
        XCTAssertTrue(model.shellCompletionAvailable)
    }

    /// The race the generation exists for: `cargo install ripgrep` is typed, `rg` is asked about and
    /// comes back unresolved, and the answer lands AFTER the install ran. Painting it would leave a
    /// perfectly good `rg` red until something else happened to run.
    func testAnAnswerFromBeforeACommandRanIsDropped() async {
        let model = typing("rg")
        // The story exactly: unresolved before the install, resolved after it.
        var installed = false
        model.whenceSink = { [verdicts] _ in
            defer { installed = true }
            return .groups(verdicts([("rg", installed ? Kind.command : Kind.none)]))
        }

        model.askShellAboutTypedCommands()
        // The install ran while the question was out — which empties the table and opens a new
        // generation, because a command is the one thing that moves the machine under a verdict.
        XCTAssertTrue(model.submitCommandPrompt(), "the line ran")
        model.commandPrompt.insert("rg")
        await drainReply()

        XCTAssertFalse(
            model.commandPrompt.spans.contains { $0.kind == .unknownCommand },
            "the machine moved under that answer, so it was thrown away",
        )
        // And the re-ask against the new generation is the one that counts.
        model.askShellAboutTypedCommands()
        await drainReply()
        XCTAssertFalse(
            model.commandPrompt.spans.contains { $0.kind == .unknownCommand },
            "the install is what the shell answers about now",
        )
    }

    /// With nothing left to ask about, the hook is free — every keystroke calls it and a settled
    /// line must not keep paying a round trip to be told the same thing.
    func testASettledLineStopsAsking() async {
        let model = typing("git")
        var asks = 0
        model.whenceSink = { [verdicts] _ in
            asks += 1
            return .groups(verdicts([("git", Kind.command)]))
        }

        model.askShellAboutTypedCommands()
        await drainReply()
        let settled = asks

        model.askShellAboutTypedCommands()
        await drainReply()
        XCTAssertEqual(asks, settled, "every word already has a verdict")
    }

    /// Tearing the wiring down re-arms the latch, because the next host may well run zsh.
    func testClearingTheWiringDropsBothSinks() {
        let model = typing("gst")
        model.whenceSink = { _ in .noShell }
        model.shellCompletionSink = { _, _ in .noShell }

        model.clearShellCompletion()

        XCTAssertNil(model.whenceSink, "the whence sink went with the completion one")
        XCTAssertNil(model.shellCompletionSink)
        XCTAssertTrue(model.shellCompletionAvailable, "and the shared latch is re-armed")
    }

    /// Lets the `Task` the ask spawned run to completion. Yielding rather than sleeping: the sink
    /// answers immediately in every test that calls this, so there is nothing to wait OUT. Generous
    /// enough for the re-ask the reply path fires, which is a second `Task` behind the first.
    private func drainReply() async {
        for _ in 0..<8 { await Task.yield() }
    }
}
