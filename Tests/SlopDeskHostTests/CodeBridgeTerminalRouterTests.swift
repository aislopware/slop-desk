import Foundation
import XCTest
@testable import SlopDeskHost

/// ``CodeBridgeTerminalRouter`` — the CROSSING, not the choice.
///
/// The choice moved: cwd confinement, the two safety gates (no agent, a shell in the foreground),
/// the closest-to-the-acting-file ranking and the deterministic tie-break are
/// `rust/slopdesk-muxsession::bridge_router`, pinned there against the same cases this file used to
/// hold. Re-asserting them here would be the cross-language mirror fixture the one-implementation
/// rule exists to prevent — the second copy is what drifts.
///
/// What is pinned HERE is the half that is genuinely this side's: a pane list flattened into records
/// over one blob, an INDEX coming back, and the negative codes turning into the two sentences the
/// editor shows. A record whose offsets were built wrong would still answer *an* index — so the
/// cases below are the ones where a marshalling bug picks the wrong pane rather than crashing.
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

    /// The index maps back to the pane the caller handed in, with a pane in front of it and one
    /// behind — an off-by-one in the record table would answer a neighbour, and a neighbour is a
    /// shell in someone else's project.
    func testTheAnsweredIndexNamesThePaneTheCallerHandedIn() throws {
        let panes = [
            pane("a", cwd: "/work/other"),
            pane("b", cwd: "/work/alpha/src"),
            pane("c", cwd: "/work/elsewhere"),
        ]

        let winner = try chosen(panes, root: "/work/alpha")
        XCTAssertEqual(winner.paneId, "b")
        XCTAssertEqual(winner.title, "pane b", "the title rides past the door untouched")
    }

    /// Three variable-length strings per record, and a pane whose cwd is ABSENT rather than empty.
    /// The absent one is what proves `has_cwd` crossed as a flag instead of being inferred from a
    /// zero length — an empty-string cwd and an unobserved cwd must not become the same pane.
    func testEachRecordFindsItsOwnFieldsInTheSharedBlob() throws {
        let panes = [
            pane("first", cwd: nil, foreground: "vim"),
            pane("second-with-a-much-longer-id", cwd: "/work/deep/nested/place", foreground: "-zsh"),
        ]

        XCTAssertEqual(try chosen(panes, root: "/work").paneId, "second-with-a-much-longer-id")
    }

    /// Ranking still has to see the acting directory, which crosses as its own optional pair.
    func testTheActingDirectoryReachesTheRanking() throws {
        let panes = [pane("a", cwd: "/work"), pane("b", cwd: "/work/src/app"), pane("c", cwd: "/work/docs")]

        XCTAssertEqual(try chosen(panes, root: "/work", near: "/work/src/app").paneId, "b")
        XCTAssertEqual(try chosen(panes, root: "/work", near: "/work/docs/notes").paneId, "c")
    }

    /// The two refusals are distinct codes and distinct sentences: they send the user to different
    /// places, and collapsing them at the door would make the feature look broken in one case and
    /// misleading in the other.
    func testEachRefusalCrossesBackAsItsOwnSentence() {
        XCTAssertEqual(refusal([pane("a", cwd: "/elsewhere")], root: "/work"), .noPaneInProject)
        XCTAssertEqual(refusal([], root: "/work"), .noPaneInProject)
        XCTAssertEqual(refusal([pane("a", cwd: "/work", agent: true)], root: "/work"), .noIdlePane)
        XCTAssertEqual(refusal([pane("a", cwd: "/work", foreground: "vim")], root: "/work"), .noIdlePane)

        for refusal in [CodeBridgeTerminalRouter.Refusal.noPaneInProject, .noIdlePane] {
            XCTAssertFalse(CodeBridgeTerminalRouter.message(for: refusal).isEmpty)
        }
        XCTAssertNotEqual(
            CodeBridgeTerminalRouter.message(for: .noIdlePane),
            CodeBridgeTerminalRouter.message(for: .noPaneInProject),
        )
    }

    // MARK: Bytes

    /// Enter is a carriage RETURN — the byte the key sends, which the tty's `ICRNL` turns into the
    /// newline the shell reads. Same convention as the agent-control `run` verb: two ways to type
    /// into a pane must not disagree about what Enter is.
    func testCommandsEndInACarriageReturn() {
        XCTAssertEqual(CodeBridgeTerminalRouter.keystrokes(for: "ls -la"), Data("ls -la\r".utf8))
    }

    /// The quoting is what stands between a project path with a space in it and a command that
    /// runs on the wrong arguments. Pinned at the crossing too because this text is typed into a
    /// live shell, and a truncated delivery would type a HALF-quoted path.
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
