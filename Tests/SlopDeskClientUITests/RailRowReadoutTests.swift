// RailRowReadoutTests — pins the row's tooltip-detail precedence ladder (question > scent > working
// label > final line > error line > running command > NOTHING), the title-echo gate on the
// command-shaped rungs, the error-line assembly, the trailing shell label, the project header's
// tooltip dialect and second-line-git / collapsed-count swap, and the agent-session classification. Headless
// VALUE assertions over the pure resolvers.

import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class RailRowReadoutTests: XCTestCase {
    // MARK: - Precedence

    /// The blocked question outranks everything — including a live scent (the agent is stopped; what
    /// it WAS doing no longer matters).
    func testQuestionWins() {
        let line = RailRowReadout.resolve(
            question: "Allow edit to Config.swift?", scent: "3/5 · Editing", workingLabel: "Wiring",
            doneLine: "Done", errorLine: "make",
        )
        XCTAssertEqual(line, "Allow edit to Config.swift?")
    }

    /// The inspector scent outranks the wire-27 label fallback while working.
    func testScentBeatsWorkingLabel() {
        let line = RailRowReadout.resolve(
            question: nil, scent: "3/5 · Editing TokenRefresh.swift", workingLabel: "Wiring rotation",
            doneLine: nil, errorLine: nil,
        )
        XCTAssertEqual(line, "3/5 · Editing TokenRefresh.swift")
    }

    /// Feed cold: the last assistant line carries the readout.
    func testWorkingLabelFallback() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: "Wiring refresh-token rotation",
            doneLine: nil, errorLine: nil,
        )
        XCTAssertEqual(line, "Wiring refresh-token rotation")
    }

    /// Done-unseen: the agent's final line — read the result without focusing the tab.
    func testDoneLineBeatsErrorLine() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: "All 34 tests pass, pushed", errorLine: "npm test",
        )
        XCTAssertEqual(line, "All 34 tests pass, pushed")
    }

    /// Error: the failing-command line (the badge's `!<code>` carries the number), outranking the
    /// running command.
    func testErrorLineBeatsCommandLine() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: "npm test", commandLine: "make check",
        )
        XCTAssertEqual(line, "npm test")
    }

    /// The RUNNING command is the floor — a busy shell's row says what it is doing.
    func testCommandLineIsTheFloor() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: "make check",
        )
        XCTAssertEqual(line, "make check")
    }

    /// Nothing live: `nil` — the row shows its title alone; there is no filler rung and no placeholder.
    func testSettledRowResolvesNothing() {
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: nil, title: "api",
        ))
    }

    // MARK: - The title-echo gate

    /// A command-shaped line that only repeats the title is dropped: equal, the command extending the
    /// title word (`npm` → `npm test`), or the title extending the command — case-insensitive.
    func testCommandEchoingTitleIsDropped() {
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: "make check", title: "make check",
        ))
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: "npm test", title: "npm",
        ))
        XCTAssertNil(RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: "Make Check", commandLine: nil, title: "make check",
        ))
    }

    /// A command that genuinely differs from the title (a folder-titled row running a build) shows.
    func testCommandDifferingFromTitleShows() {
        let line = RailRowReadout.resolve(
            question: nil, scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, commandLine: "npm test", title: "SlopDeskClientUI",
        )
        XCTAssertEqual(line, "npm test")
    }

    /// The echo gate is WORD-bounded (`api` never swallows `apitool run`) and never touches the
    /// prose rungs — a question quoting the title is still news.
    func testEchoGateIsWordBoundedAndProseExempt() {
        XCTAssertFalse(RailRowReadout.echoesTitle("apitool run", title: "api"))
        XCTAssertTrue(RailRowReadout.echoesTitle("npm test", title: "npm"))
        XCTAssertTrue(RailRowReadout.echoesTitle("npm", title: "npm test"))
        XCTAssertFalse(RailRowReadout.echoesTitle("", title: "npm"))
        let question = RailRowReadout.resolve(
            question: "make check", scent: nil, workingLabel: nil,
            doneLine: nil, errorLine: nil, title: "make check",
        )
        XCTAssertEqual(question, "make check")
    }

    // MARK: - The trailing shell label

    /// The row's resting trailing label keeps bare shells (`zsh` — the otty idle row wears its shell
    /// name), basenames a path, and strips the login-shell `-` — unlike the TITLE fallback, which
    /// suppresses shells.
    func testShellLabelKeepsBareShells() {
        XCTAssertEqual(RailRowsBuilder.shellLabel("zsh"), "zsh")
        XCTAssertEqual(RailRowsBuilder.shellLabel("-zsh"), "zsh")
        XCTAssertEqual(RailRowsBuilder.shellLabel("/usr/local/bin/claude"), "claude")
        XCTAssertEqual(RailRowsBuilder.shellLabel(" vim \n"), "vim")
        XCTAssertNil(RailRowsBuilder.shellLabel(nil))
        XCTAssertNil(RailRowsBuilder.shellLabel("  "))
    }

    // MARK: - The project header's tooltip

    /// The header tooltip: full project path, then the git line — only the non-empty parts.
    func testHeaderTooltipJoinsPathAndGitLine() {
        let summary = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 0, changedCount: 4, staged: 1, modified: 3,
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.tooltip(projectKey: "/Users/abner/w/api", summary: summary),
            "/Users/abner/w/api\nmain >2 +1 !3",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.tooltip(projectKey: "/Users/abner/w/api", summary: nil),
            "/Users/abner/w/api",
        )
        XCTAssertNil(SidebarSectionHeaderRow.tooltip(projectKey: nil, summary: nil))
    }

    /// The header's two slots swap by collapse state: OPEN ⇒ the git line on the second line (or no
    /// second line for a non-repo / unknown project) and an empty trailing slot; COLLAPSED ⇒ the
    /// second line folds away and the trailing slot carries the hidden-row count (the otty
    /// collapsed-header number), with the impossible zero-count guarded to nothing.
    func testHeaderDetailAndCountSwap() {
        let summary = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 0, changedCount: 3, staged: 0, modified: 3,
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.detailLine(collapsed: false, summary: summary),
            "main >2 !3",
        )
        XCTAssertNil(SidebarSectionHeaderRow.detailLine(collapsed: false, summary: nil))
        XCTAssertNil(SidebarSectionHeaderRow.detailLine(collapsed: true, summary: summary))
        XCTAssertNil(SidebarSectionHeaderRow.trailingCount(collapsed: false, count: 3))
        XCTAssertEqual(SidebarSectionHeaderRow.trailingCount(collapsed: true, count: 3), "3")
        XCTAssertEqual(SidebarSectionHeaderRow.trailingCount(collapsed: true, count: 1), "1")
        XCTAssertNil(SidebarSectionHeaderRow.trailingCount(collapsed: true, count: 0))
    }

    /// The git line speaks the `__git_ps1` sigil dialect — branch first, only the NON-ZERO counts,
    /// fixed order; a non-repo summary yields nothing; a repo with no branch reads "detached".
    func testGitLineDialect() {
        XCTAssertEqual(
            SidebarSectionHeaderRow.gitLine(PaneGitSummary(
                hasRepo: true, branch: "main", ahead: 1, behind: 2, changedCount: 0,
            )),
            "main >1 <2",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.gitLine(PaneGitSummary(
                hasRepo: true, branch: "", ahead: 0, behind: 0, changedCount: 0,
            )),
            "detached",
        )
        XCTAssertNil(SidebarSectionHeaderRow.gitLine(PaneGitSummary(
            hasRepo: false, branch: "", ahead: 0, behind: 0, changedCount: 0,
        )))
    }

    // MARK: - The error line

    /// The error detail is the failing COMMAND alone, gated on real failure evidence. No exit code or
    /// no command → `nil` (the badge stands alone; the tooltip stays quiet about exit codes).
    func testErrorLineComposition() {
        XCTAssertEqual(RailRowReadout.errorLine(exitCode: 137, commandText: "npm test"), "npm test")
        XCTAssertEqual(RailRowReadout.errorLine(exitCode: 137, commandText: " npm test\n"), "npm test")
        XCTAssertNil(RailRowReadout.errorLine(exitCode: 1, commandText: "  "))
        XCTAssertNil(RailRowReadout.errorLine(exitCode: 1, commandText: nil))
        XCTAssertNil(RailRowReadout.errorLine(exitCode: nil, commandText: "npm test"))
    }

    // MARK: - Agent-session classification

    /// ANY agent-status verdict makes a session — `.idle` included: an agent resting at its prompt is
    /// still a session, so the classification holds instead of breathing between turns.
    func testAnyAgentStatusIsASession() {
        for status in [ClaudeStatus.idle, .working, .done, .needsPermission] {
            XCTAssertTrue(
                RailRowsBuilder.isAgentSession(status: status, processLabel: nil),
                "\(status) is an agent session",
            )
        }
    }

    /// A known agent CLI in the foreground classifies BEFORE any verdict lands (the pre-detector
    /// window); path + login-dash forms are cleaned first.
    func testAgentProcessClassifies() {
        XCTAssertTrue(RailRowsBuilder.isAgentSession(status: .none, processLabel: "claude"))
        XCTAssertTrue(RailRowsBuilder.isAgentSession(status: .none, processLabel: "/usr/local/bin/codex"))
        XCTAssertTrue(RailRowsBuilder.isAgentSession(status: .none, processLabel: "Claude"))
    }

    /// Plain shells and ordinary programs are NOT sessions.
    func testShellsAndCommandsAreNotSessions() {
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: nil))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "zsh"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "-zsh"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "make"))
        XCTAssertFalse(RailRowsBuilder.isAgentSession(status: .none, processLabel: "vim"))
    }
}
