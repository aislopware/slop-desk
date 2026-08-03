import Foundation
import XCTest
@testable import SlopDeskHost

/// ``CodeBridgeTerminalRouter`` — which pane a command from the embedded editor lands in.
///
/// This is the file to read before changing that choice. The router's failure mode is REFUSING,
/// because the alternative is typing a shell command somewhere the user did not mean: into another
/// project, into a running build, or — worst — at an agent's prompt, where it becomes a message to
/// the agent rather than a command to a shell.
final class CodeBridgeTerminalRouterTests: XCTestCase {
    private func pane(
        _ id: String, cwd: String?, agent: Bool = false, foreground: String = "zsh",
    ) -> CodeBridgePane {
        CodeBridgePane(
            paneId: id, title: "pane \(id)", cwd: cwd, hasAgent: agent, foreground: foreground,
        )
    }

    private func chosen(
        _ panes: [CodeBridgePane], root: String, near directory: String? = nil,
    ) throws -> CodeBridgePane {
        try CodeBridgeTerminalRouter.choose(among: panes, root: root, near: directory).get()
    }

    private func refusal(
        _ panes: [CodeBridgePane], root: String, near directory: String? = nil,
    ) -> CodeBridgeTerminalRouter.Refusal? {
        switch CodeBridgeTerminalRouter.choose(among: panes, root: root, near: directory) {
        case .success: nil
        case let .failure(refusal): refusal
        }
    }

    // MARK: Containment

    func testTheCommandStaysInsideItsOwnProject() throws {
        let panes = [pane("a", cwd: "/work/other"), pane("b", cwd: "/work/alpha/src")]

        XCTAssertEqual(try chosen(panes, root: "/work/alpha").paneId, "b")
    }

    /// A pane whose cwd was never observed is not a candidate: containment is the only thing
    /// keeping the command in this project, and an unknown cwd cannot be contained.
    func testAPaneWithNoObservedCWDIsNeverChosen() {
        XCTAssertEqual(refusal([pane("a", cwd: nil)], root: "/work"), .noPaneInProject)
    }

    func testNoPaneInTheProjectRefuses() {
        XCTAssertEqual(refusal([pane("a", cwd: "/elsewhere")], root: "/work"), .noPaneInProject)
        XCTAssertEqual(refusal([], root: "/work"), .noPaneInProject)
    }

    // MARK: The two safety gates

    /// The one that matters most: a pane hosting an agent is skipped even though its foreground
    /// process is a shell between turns. Typing `npm test` at Claude Code's prompt does not run
    /// `npm test` — it SAYS "npm test" to the agent.
    func testAnAgentsPaneIsNeverTypedInto() {
        let panes = [pane("a", cwd: "/work", agent: true)]

        XCTAssertEqual(refusal(panes, root: "/work"), .noIdlePane)
    }

    /// A pane in vim, in a pager, or mid-build is not waiting for a command line — its keystrokes
    /// mean something else entirely.
    func testABusyPaneIsNeverTypedInto() {
        for foreground in ["vim", "less", "node", "swift", "ssh", ""] {
            let panes = [pane("a", cwd: "/work", foreground: foreground)]
            XCTAssertEqual(refusal(panes, root: "/work"), .noIdlePane, "busy in \(foreground)")
        }
    }

    /// Login shells arrive from the process table with a leading dash; the same pane must not
    /// become ineligible because the user logged in rather than spawned a subshell.
    func testLoginShellsCount() throws {
        XCTAssertEqual(try chosen([pane("a", cwd: "/work", foreground: "-zsh")], root: "/work").paneId, "a")
    }

    /// Busy panes exist but none can take it ⇒ a DIFFERENT refusal from "no pane at all", because
    /// the two sentences send the user to different places.
    func testBusyAndAbsentAreDistinctRefusals() {
        XCTAssertEqual(refusal([pane("a", cwd: "/work", foreground: "vim")], root: "/work"), .noIdlePane)
        XCTAssertNotEqual(
            CodeBridgeTerminalRouter.message(for: .noIdlePane),
            CodeBridgeTerminalRouter.message(for: .noPaneInProject),
        )
    }

    // MARK: Ranking

    /// With several idle shells, the one standing closest to the acting file wins — running a
    /// command about `src/app` in the pane already sitting there is what the user would have done.
    func testTheClosestPaneToTheFileWins() throws {
        let panes = [
            pane("a", cwd: "/work"),
            pane("b", cwd: "/work/src/app"),
            pane("c", cwd: "/work/docs"),
        ]

        XCTAssertEqual(try chosen(panes, root: "/work", near: "/work/src/app").paneId, "b")
        XCTAssertEqual(try chosen(panes, root: "/work", near: "/work/docs/notes").paneId, "c")
    }

    /// Nothing to rank on (a selection run with no file directory, or a tie) still resolves the
    /// same way every time — a coin-flip target would make the feature untrustworthy, not just
    /// unpredictable.
    func testTheChoiceIsDeterministic() throws {
        let panes = [pane("b9", cwd: "/work"), pane("a1", cwd: "/work")]

        XCTAssertEqual(try chosen(panes, root: "/work").paneId, "a1")
        XCTAssertEqual(try chosen(panes.reversed(), root: "/work").paneId, "a1")
    }

    func testSharedComponentsCountsComponentsNotCharacters() {
        XCTAssertEqual(CodeBridgeTerminalRouter.sharedComponents("/a/b/c", "/a/b/d"), 2)
        XCTAssertEqual(CodeBridgeTerminalRouter.sharedComponents("/a/bee", "/a/b"), 1)
        XCTAssertEqual(CodeBridgeTerminalRouter.sharedComponents("/a/b", nil), 0)
    }

    // MARK: Bytes

    /// Enter is a carriage RETURN — the byte the key sends, which the tty's `ICRNL` turns into the
    /// newline the shell reads. Same convention as the agent-control `run` verb: two ways to type
    /// into a pane must not disagree about what Enter is.
    func testCommandsEndInACarriageReturn() {
        XCTAssertEqual(
            CodeBridgeTerminalRouter.keystrokes(for: "ls -la"), Data("ls -la\r".utf8),
        )
    }

    /// The quoting is what stands between a project path with a space in it and a command that
    /// runs on the wrong arguments.
    func testChangeDirectoryQuotesHostilePaths() {
        XCTAssertEqual(
            CodeBridgeTerminalRouter.changeDirectoryCommandLine("/work/my project"),
            "cd '/work/my project'",
        )
        XCTAssertEqual(
            CodeBridgeTerminalRouter.changeDirectoryCommandLine("/work/it's here"),
            #"cd '/work/it'\''s here'"#,
        )
    }
}
