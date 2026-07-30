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

    // MARK: - The trailing slot suppresses bare shells

    /// The trailing slot shares the TITLE's `processDisplayName` cleanup: a bare login shell shows
    /// NOTHING (an idle row labelled "zsh" says as little as "Terminal" — herdr never shows a shell
    /// name), while a real foreground program labels the slot.
    func testTrailingSlotSuppressesBareShells() {
        XCTAssertNil(RailRowsBuilder.processDisplayName("zsh"))
        XCTAssertNil(RailRowsBuilder.processDisplayName("-zsh"))
        XCTAssertEqual(RailRowsBuilder.processDisplayName("/usr/local/bin/claude"), "claude")
        XCTAssertEqual(RailRowsBuilder.processDisplayName(" vim \n"), "vim")
        XCTAssertNil(RailRowsBuilder.processDisplayName(nil))
        XCTAssertNil(RailRowsBuilder.processDisplayName("  "))
    }

    // MARK: - The program-set title cleanup

    /// `strippedProgramTitle` drops exactly ONE leading agent-activity glyph (braille spinner frame /
    /// `·✢✳✶✻✽`, variation selector tolerated) when followed by whitespace/end — any other leading
    /// symbol is user content and stays; whitespace-only / empty collapse to `nil`.
    func testStrippedProgramTitleDropsOneAgentGlyph() {
        XCTAssertEqual(RailRowsBuilder.strippedProgramTitle("⠙ Explain FEC recovery"), "Explain FEC recovery")
        XCTAssertEqual(RailRowsBuilder.strippedProgramTitle("✳ topic"), "topic")
        XCTAssertEqual(RailRowsBuilder.strippedProgramTitle("✳\u{FE0E} topic"), "topic")
        XCTAssertEqual(RailRowsBuilder.strippedProgramTitle("main.swift - NVIM"), "main.swift - NVIM")
        XCTAssertEqual(RailRowsBuilder.strippedProgramTitle("★ production"), "★ production")
        XCTAssertEqual(
            RailRowsBuilder.strippedProgramTitle("task ⠋ detail"), "task ⠋ detail",
            "a glyph past the first character is content, not an activity prefix",
        )
        XCTAssertNil(RailRowsBuilder.strippedProgramTitle("✳"), "a bare glyph carries no title")
        XCTAssertNil(RailRowsBuilder.strippedProgramTitle(nil))
        XCTAssertNil(RailRowsBuilder.strippedProgramTitle("   "))
    }

    // MARK: - The project header's tooltip

    /// The header tooltip: full project path, then the git line — only the non-empty parts.
    func testHeaderTooltipJoinsPathAndGitLine() {
        let summary = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 0, changedCount: 4, staged: 1, modified: 3,
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.tooltip(projectKey: "/Users/abner/w/api", summary: summary),
            "/Users/abner/w/api\nmain ↑2 +1 !3",
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
            "main ↑2 !3",
        )
        XCTAssertNil(SidebarSectionHeaderRow.detailLine(collapsed: false, summary: nil))
        XCTAssertNil(SidebarSectionHeaderRow.detailLine(collapsed: true, summary: summary))
        XCTAssertNil(SidebarSectionHeaderRow.trailingCount(collapsed: false, count: 3))
        XCTAssertEqual(SidebarSectionHeaderRow.trailingCount(collapsed: true, count: 3), "3")
        XCTAssertEqual(SidebarSectionHeaderRow.trailingCount(collapsed: true, count: 1), "1")
        XCTAssertNil(SidebarSectionHeaderRow.trailingCount(collapsed: true, count: 0))
    }

    /// The git line speaks the prompt-theme sigil dialect (`↑↓ + ! ? ~ $`) — branch first, only the
    /// NON-ZERO counts, fixed order; a non-repo summary yields nothing; a repo with no branch reads
    /// "detached".
    func testGitLineDialect() {
        XCTAssertEqual(
            SidebarSectionHeaderRow.gitLine(PaneGitSummary(
                hasRepo: true, branch: "main", ahead: 1, behind: 2, changedCount: 0,
            )),
            "main ↑1 ↓2",
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

    // MARK: - The git line's ink roles

    /// Every run of the git line carries its OWN ink role, so the counts read at a glance instead of
    /// dissolving into one flat metadata grey. The dialect (order, sigils, non-zero-only) is unchanged —
    /// `gitLine` is derived from these segments, so the two can never drift apart.
    func testGitSegmentsCarryPerSigilInkRoles() {
        let busy = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 1, behind: 2, changedCount: 9,
            staged: 3, modified: 4, untracked: 5, conflicted: 6, stash: 7,
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.gitSegments(busy).map(\.ink),
            [.branch, .divergence, .divergence, .staged, .modified, .untracked, .conflicted, .stash],
            "one role per run, in the dialect's fixed order",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.gitSegments(busy).map(\.text).joined(separator: " "),
            SidebarSectionHeaderRow.gitLine(busy),
            "the plain line (tooltip / a11y) is the segments joined — one source of truth",
        )
    }

    /// A quiet repo is JUST the branch run, and a non-repo has no segments at all (so the header shows
    /// no second line rather than an empty coloured one).
    func testGitSegmentsQuietAndNonRepo() {
        XCTAssertEqual(
            SidebarSectionHeaderRow.gitSegments(PaneGitSummary(
                hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 0,
            )),
            [.init(text: "main", ink: .branch)],
            "a clean tracking branch is one run",
        )
        XCTAssertTrue(
            SidebarSectionHeaderRow.gitSegments(PaneGitSummary(
                hasRepo: false, branch: "", ahead: 0, behind: 0, changedCount: 0,
            )).isEmpty,
            "no repo ⇒ no runs",
        )
    }

    // MARK: - The git line's compact (long-branch) form

    /// When the branch name eats the line, the counts fold to their bare SIGILS instead of truncating
    /// away with it: same runs, same order, same inks — the number goes, the state stays. The branch
    /// itself has no compact form (it truncates), so it drops out of the folded readout entirely.
    func testCompactStatusKeepsSigilsAndDropsCounts() {
        let busy = PaneGitSummary(
            hasRepo: true, branch: "feature/a-very-long-branch-name", ahead: 12, behind: 3,
            changedCount: 9, staged: 30, modified: 4, untracked: 5, conflicted: 6, stash: 7,
        )
        let compact = SidebarSectionHeaderRow.compactStatus(SidebarSectionHeaderRow.gitSegments(busy))
        XCTAssertEqual(
            compact.map(\.text), ["↑", "↓", "+", "!", "?", "~", "$"],
            "every sigil survives the fold; every count goes",
        )
        XCTAssertEqual(
            compact.map(\.ink),
            [.divergence, .divergence, .staged, .modified, .untracked, .conflicted, .stash],
            "the fold changes the text, never the ink role",
        )
        XCTAssertTrue(
            compact.allSatisfy { !$0.text.contains(where: \.isNumber) },
            "no digits survive — width is the whole point",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.gitLine(busy),
            "feature/a-very-long-branch-name ↑12 ↓3 +30 !4 ?5 ~6 $7",
            "the counts retreat to the tooltip / a11y line, they are not lost",
        )
    }

    /// A quiet repo folds to NOTHING — there are no sigils to keep, so the tight form is just the
    /// (truncating) branch, and a non-repo has no line at all.
    func testCompactStatusEmptyWhenNothingToReport() {
        XCTAssertTrue(
            SidebarSectionHeaderRow.compactStatus(SidebarSectionHeaderRow.gitSegments(PaneGitSummary(
                hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 0,
            ))).isEmpty,
            "a clean branch has no readout to fold",
        )
        XCTAssertNil(
            SidebarSectionHeaderRow.GitSegment(text: "main", ink: .branch).symbol,
            "the branch is a name, not a sigil",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.GitSegment(text: "↑12", ink: .divergence).symbol, "↑",
        )
    }

    /// The four WORKTREE states form a RAMP — `+staged` → `!modified` → `?untracked` → `~conflicted` is
    /// "how far this work is from being committed", and the filter's chromatics sweep it monotonically
    /// (green→yellow→orange→red, hue 126.9°→89.2°→51.5°→9.8° on the default theme) in the SAME order the
    /// sigils appear. Divergence and stash sit OFF the ramp on cool hues (neither is a worktree state),
    /// and the branch keeps the body ink.
    @MainActor
    func testGitInkRampAndOffRampRoles() {
        XCTAssertEqual(SidebarSectionHeaderRow.ink(.staged), Slate.Status.ok)
        XCTAssertEqual(SidebarSectionHeaderRow.ink(.modified), Slate.Status.warn)
        XCTAssertEqual(SidebarSectionHeaderRow.ink(.untracked), Slate.Chroma.orange)
        XCTAssertEqual(SidebarSectionHeaderRow.ink(.conflicted), Slate.Status.err)
        XCTAssertEqual(SidebarSectionHeaderRow.ink(.divergence), Slate.Status.info)
        XCTAssertEqual(SidebarSectionHeaderRow.ink(.stash), Slate.Chroma.purple)
        XCTAssertEqual(SidebarSectionHeaderRow.ink(.branch), Slate.Text.secondary)
    }

    /// No two runs share an ink, and none falls back to the tertiary metadata grey — the flat grey was
    /// the original bug, and a duplicate would silently re-merge two states the sigils keep apart.
    @MainActor
    func testEveryGitRunHasItsOwnInkAndNoneIsTheMetadataGrey() {
        let inks = SidebarSectionHeaderRow.GitInk.allCases.map { SidebarSectionHeaderRow.ink($0) }
        for (role, colour) in zip(SidebarSectionHeaderRow.GitInk.allCases, inks) {
            XCTAssertNotEqual(colour, Slate.Text.tertiary, "\(role) must not sink into the flat grey")
            XCTAssertEqual(
                inks.filter { $0 == colour }.count, 1, "\(role) shares its ink with another run",
            )
        }
    }

    /// The weight ladder has three rungs: every COUNT is heavy (at 10 pt mono a regular weight leaves the
    /// readout thin enough that colour does all the work), the BRANCH stays regular so the counts read as
    /// a group beside it, and `~conflicted` steps one further — the palette ranks it FOURTH by contrast
    /// (5.7:1) behind `!modified` (11.9:1), so the state that needs a human pulls least. Re-assigning hues
    /// cannot fix that without lying about what the states mean; weight is the channel outside the
    /// palette, so it holds on every theme and under the protanopia collapse that puts `+staged` and
    /// `~conflicted` ~3 ΔE apart.
    func testWeightLadderRanksCountsAboveBranchAndConflictAboveAll() {
        XCTAssertEqual(SidebarSectionHeaderRow.weight(.branch), .regular, "the branch is identity, not a count")
        XCTAssertEqual(SidebarSectionHeaderRow.weight(.conflicted), .bold, "the one state that needs a human")
        for role in SidebarSectionHeaderRow.GitInk.allCases where role != .branch && role != .conflicted {
            XCTAssertEqual(
                SidebarSectionHeaderRow.weight(role), .semibold,
                "\(role) is a count — heavy enough to read without colour carrying it alone",
            )
        }
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
