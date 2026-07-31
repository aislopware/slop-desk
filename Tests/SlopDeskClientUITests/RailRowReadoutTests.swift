// RailRowReadoutTests — pins the row's tooltip-detail precedence ladder (question > scent > working
// label > final line > error line > running command > NOTHING), the title-echo gate on the
// command-shaped rungs, the error-line assembly, the trailing shell label, the project header's
// tooltip dialect and second-line-git / collapsed-count swap, and the agent-session classification. Headless
// VALUE assertions over the pure resolvers.

import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
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

    /// `normalizedProgramTitle` maps exactly ONE leading agent-activity glyph (braille spinner frame /
    /// `·✢✳✶✻✽`, variation selector tolerated) onto the canonical static `✳\u{FE0E}` mark when
    /// followed by whitespace/end — the mark SHOWS (it used to be dropped) without the title text
    /// changing per animation frame. Any other leading symbol is user content and stays;
    /// whitespace-only / empty collapse to `nil`.
    func testNormalizedProgramTitleCanonicalizesTheAgentGlyph() {
        let mark = RailRowsBuilder.agentTitleMark
        XCTAssertEqual(
            RailRowsBuilder.normalizedProgramTitle("⠙ Explain FEC recovery"),
            "\(mark) Explain FEC recovery",
        )
        XCTAssertEqual(RailRowsBuilder.normalizedProgramTitle("✳ topic"), "\(mark) topic")
        XCTAssertEqual(
            RailRowsBuilder.normalizedProgramTitle("\(mark) topic"), "\(mark) topic",
            "an already-normalized title is a fixed point",
        )
        // THE FLICKER KILL: every frame of the spinner family yields the IDENTICAL string, so an
        // animating agent title never changes the row text tick to tick.
        XCTAssertEqual(
            RailRowsBuilder.normalizedProgramTitle("⠹ build"),
            RailRowsBuilder.normalizedProgramTitle("⠸ build"),
        )
        XCTAssertEqual(
            RailRowsBuilder.normalizedProgramTitle("✻ build"),
            RailRowsBuilder.normalizedProgramTitle("· build"),
        )
        XCTAssertEqual(RailRowsBuilder.normalizedProgramTitle("main.swift - NVIM"), "main.swift - NVIM")
        XCTAssertEqual(RailRowsBuilder.normalizedProgramTitle("★ production"), "★ production")
        XCTAssertEqual(
            RailRowsBuilder.normalizedProgramTitle("task ⠋ detail"), "task ⠋ detail",
            "a glyph past the first character is content, not an activity prefix",
        )
        XCTAssertNil(RailRowsBuilder.normalizedProgramTitle("✳"), "a bare glyph carries no title")
        XCTAssertNil(RailRowsBuilder.normalizedProgramTitle(nil))
        XCTAssertNil(RailRowsBuilder.normalizedProgramTitle("   "))
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

    // MARK: - The git line's shed ladder

    /// Narrower than the folded form, the readout starts GIVING UP runs rather than crowding the branch
    /// into a stub — least important first: `$` stash (parked on purpose), then `↑↓` divergence (unpushed
    /// commits are safely committed), then `?` untracked (mostly build output). What survives is the
    /// WORKTREE — `+staged !modified ~conflicted`, the states that say whether this project is safe to
    /// leave. Both divergence runs go together: `↑` and `↓` are one fact about the same remote.
    func testShedLadderDropsBookkeepingBeforeWorktree() {
        let busy = PaneGitSummary(
            hasRepo: true, branch: "feature/a-very-long-branch-name", ahead: 12, behind: 3,
            changedCount: 9, staged: 30, modified: 4, untracked: 5, conflicted: 6, stash: 7,
        )
        let status = SidebarSectionHeaderRow.compactStatus(SidebarSectionHeaderRow.gitSegments(busy))
        XCTAssertEqual(
            SidebarSectionHeaderRow.shedding(status, to: 0).map(\.text), ["↑", "↓", "+", "!", "?", "~", "$"],
            "rung 0 sheds nothing",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.shedding(status, to: 1).map(\.text), ["↑", "↓", "+", "!", "?", "~"],
            "the stash parks itself first",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.shedding(status, to: 2).map(\.text), ["+", "!", "?", "~"],
            "one rung is a ROLE — both divergence runs are one fact and leave together",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.shedding(status, to: 3).map(\.text), ["+", "!", "~"],
            "untracked goes last of the three; the worktree core is what the deepest rung keeps",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.gitLine(busy),
            "feature/a-very-long-branch-name ↑12 ↓3 +30 !4 ?5 ~6 $7",
            "a shed run is not lost — the tooltip / a11y line still speaks every one",
        )
    }

    /// The LAST run standing is never shed: a line that reports nothing is not a tighter readout, it is a
    /// missing one. A repo whose only dirt is `↑2` keeps its `↑` at any width, however low the ladder ranks
    /// divergence.
    func testShedLadderNeverEmptiesTheReadout() {
        let ahead = SidebarSectionHeaderRow.compactStatus(SidebarSectionHeaderRow.gitSegments(
            PaneGitSummary(hasRepo: true, branch: "main", ahead: 2, behind: 0, changedCount: 0),
        ))
        XCTAssertEqual(ahead.map(\.text), ["↑"])
        for level in 0...SidebarSectionHeaderRow.shedLadder.count {
            XCTAssertEqual(
                SidebarSectionHeaderRow.shedding(ahead, to: level).map(\.text), ["↑"],
                "the only run reporting anything survives rung \(level)",
            )
        }
        XCTAssertTrue(
            SidebarSectionHeaderRow.shedding([], to: 3).isEmpty,
            "nothing to report stays nothing — the tight form is just the branch",
        )
        // A role the line never had costs no rung: a worktree-only repo spends rung 1 on a state it
        // actually shows, instead of burning the ladder shedding sigils that were never there.
        let worktreeOnly = SidebarSectionHeaderRow.compactStatus(SidebarSectionHeaderRow.gitSegments(
            PaneGitSummary(
                hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 2,
                staged: 1, modified: 1,
            ),
        ))
        XCTAssertEqual(worktreeOnly.map(\.text), ["+", "!"])
        XCTAssertEqual(
            SidebarSectionHeaderRow.shedding(worktreeOnly, to: 1).map(\.text), ["!"],
            "absent roles are skipped, so the first rung narrows the line for real",
        )
    }

    /// The ladder ranks every role exactly once, so no run can be shed twice or made unsheddable by
    /// omission — the paint rungs walk this list, and a missing role would silently pin itself on screen.
    func testShedLadderCoversEveryRoleOnce() {
        XCTAssertEqual(
            Set(SidebarSectionHeaderRow.shedLadder), Set(SidebarSectionHeaderRow.GitInk.allCases.filter {
                $0 != .branch
            }),
            "every status role has a rank; the branch is not a status and has none",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.shedLadder.count, Set(SidebarSectionHeaderRow.shedLadder).count,
            "no role is ranked twice",
        )
        XCTAssertEqual(
            SidebarSectionHeaderRow.shedLadder.suffix(3), [.staged, .modified, .conflicted],
            "the worktree core sits at the far end of the ladder — it leaves last",
        )
    }

    /// TWO registers, not a palette: the branch keeps the body-secondary ink, and every COUNT steps up to
    /// the primary text ink — brighter than the name beside it. The sigils already say WHICH state each
    /// run reports, so hue was restating the glyph and turning a column of folder names into a paint chart.
    @MainActor
    func testGitCountsTakeTheBodyInkAndOnlyTheBranchStaysDim() {
        for role in SidebarSectionHeaderRow.GitInk.allCases where role != .branch {
            XCTAssertEqual(
                SidebarSectionHeaderRow.ink(role), Slate.Text.primary,
                "\(role) is a count — it takes the bright body ink, not a hue of its own",
            )
        }
        XCTAssertEqual(SidebarSectionHeaderRow.ink(.branch), Slate.Text.secondary)
        XCTAssertNotEqual(
            SidebarSectionHeaderRow.ink(.branch), SidebarSectionHeaderRow.ink(.modified),
            "the counts must out-read the branch — that step IS the readout",
        )
    }

    /// No run falls back to the tertiary metadata grey — sinking the line into that flat grey is what made
    /// a conflict count read exactly like a branch name.
    @MainActor
    func testNoGitRunSinksIntoTheMetadataGrey() {
        for role in SidebarSectionHeaderRow.GitInk.allCases {
            XCTAssertNotEqual(
                SidebarSectionHeaderRow.ink(role), Slate.Text.tertiary,
                "\(role) must not sink into the flat grey",
            )
        }
    }

    /// The weight ladder has two rungs: every COUNT is bold (with hue gone the readout has only brightness
    /// and weight left, and at 10 pt mono a lighter run is thin enough that brightness carries it alone),
    /// and the BRANCH stays regular so the counts read as one group beside the name.
    func testWeightLadderRanksCountsAboveBranch() {
        XCTAssertEqual(SidebarSectionHeaderRow.weight(.branch), .regular, "the branch is identity, not a count")
        for role in SidebarSectionHeaderRow.GitInk.allCases where role != .branch {
            XCTAssertEqual(
                SidebarSectionHeaderRow.weight(role), .bold,
                "\(role) is a count — bold is half of the two channels the line has left",
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
