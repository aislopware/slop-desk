// SidebarGitLineTests — the header's GIT DIALECT as it arrives on this side.
//
// The dialect itself is `slopdesk_workspace::git_line` and its arithmetic is pinned there: the
// order, the ladder, which rung a role leaves on, which run survives. What is pinned HERE is the
// crossing and the spelling — that a `↑` and a `2` arrive as two fields and leave as one string,
// that the branch's text is this side's and its detached reading is not, and that eight runs come
// back through a boundary that carries no text at all.
//
// Deliberately NOT thinned to "the door answered something". A boundary suite that only checks the
// call succeeded cannot tell a dialect from a table of zeroes, and this line had no suite of any
// kind until docs/56 stage D — it was private to a SwiftUI view, and the squeeze ladder could only
// ever be judged by looking at `MacChromeSnapshotRender`'s render.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

final class SidebarGitLineTests: XCTestCase {
    /// The whole vocabulary, in the fixed prompt-theme order every git prompt already taught the eye.
    private let busy = PaneGitSummary(
        hasRepo: true, branch: "main", ahead: 2, behind: 1, changedCount: 9, staged: 3, modified: 4,
        untracked: 5, conflicted: 6, stash: 7,
    )

    // MARK: - The spelling

    func testSegmentsAreTheBranchThenTheSigilsInDialectOrder() {
        let runs = SidebarGitLine.segments(busy)
        XCTAssertEqual(runs.map(\.text), ["main", "↑2", "↓1", "+3", "!4", "?5", "~6", "$7"])
        XCTAssertEqual(
            runs.map(\.ink),
            [.branch, .divergence, .divergence, .staged, .modified, .untracked, .conflicted, .stash],
        )
    }

    /// A zero count is ABSENT, not `+0` — the readout says what is live, never what is not.
    func testZeroCountsAreOmitted() {
        let clean = PaneGitSummary(hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 0)
        XCTAssertEqual(SidebarGitLine.segments(clean).map(\.text), ["main"])
    }

    /// A plain directory has no git concept — not an empty line, no line at all.
    func testNonRepoHasNoSegmentsAndNoLine() {
        let plain = PaneGitSummary(hasRepo: false, branch: "", ahead: 0, behind: 0, changedCount: 0)
        XCTAssertTrue(SidebarGitLine.segments(plain).isEmpty)
        XCTAssertNil(SidebarGitLine.line(plain))
    }

    /// A detached HEAD still has an identity run — the line without one would start at a sigil and
    /// read as a readout with no subject. The RULE says the branch had no name; the WORD is this
    /// side's, which is the one piece of text the crossing does not carry.
    func testEmptyBranchReadsAsDetached() {
        let detached = PaneGitSummary(hasRepo: true, branch: "", ahead: 0, behind: 0, changedCount: 0)
        XCTAssertEqual(SidebarGitLine.segments(detached).map(\.text), ["detached"])
    }

    /// The branch's text is the caller's own string, never anything the dialect holds — so a name
    /// with a sigil in it survives verbatim rather than being read as a run.
    func testTheBranchCarriesTheCallersOwnName() {
        let odd = PaneGitSummary(
            hasRepo: true, branch: "feature/~weird+name", ahead: 0, behind: 0, changedCount: 0,
        )
        XCTAssertEqual(SidebarGitLine.segments(odd).map(\.text), ["feature/~weird+name"])
    }

    /// The painted line and the SPOKEN one are the same runs joined — they cannot drift.
    func testLineIsTheSegmentsJoined() {
        XCTAssertEqual(SidebarGitLine.line(busy), "main ↑2 ↓1 +3 !4 ?5 ~6 $7")
    }

    /// A count larger than the crossing's `uint32_t` SATURATES rather than trapping. These are
    /// counts a remote host folded, and a rail that crashes on a hostile number is a worse answer
    /// than one that prints a large one.
    func testAnAbsurdCountSaturatesRatherThanTrapping() {
        let absurd = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 0,
            modified: Int(UInt32.max) + 5,
        )
        XCTAssertEqual(SidebarGitLine.segments(absurd).map(\.text), ["main", "!\(UInt32.max)"])
    }

    // MARK: - The header's two slots

    /// Collapsing folds the git line away — the hidden-row count speaks in its place, and a header
    /// carrying both would say two things on one line.
    func testCollapsedHeaderTradesTheGitLineForTheCount() {
        XCTAssertNil(SidebarGitLine.detailSummary(collapsed: true, summary: busy))
        XCTAssertNotNil(SidebarGitLine.detailSummary(collapsed: false, summary: busy))
        XCTAssertEqual(SidebarGitLine.trailingCount(collapsed: true, count: 3), "3")
        XCTAssertNil(SidebarGitLine.trailingCount(collapsed: false, count: 3))
        XCTAssertNil(SidebarGitLine.trailingCount(collapsed: true, count: 0))
    }

    /// A directory with no repo has nothing for the second line either — the slot is hidden, not
    /// drawn empty.
    func testAnOpenHeaderWithNoRepoStillHasNoDetailLine() {
        let plain = PaneGitSummary(hasRepo: false, branch: "", ahead: 0, behind: 0, changedCount: 0)
        XCTAssertNil(SidebarGitLine.detailSummary(collapsed: false, summary: plain))
        XCTAssertNil(SidebarGitLine.detailSummary(collapsed: false, summary: nil))
    }

    /// The tooltip carries the FULL path (the name line shows only the basename) then the git line;
    /// a missing half is dropped rather than leaving a blank line in the bubble.
    func testTooltipIsThePathThenTheLine() {
        XCTAssertEqual(SidebarGitLine.tooltip(projectKey: "/w/api", summary: busy), "/w/api\nmain ↑2 ↓1 +3 !4 ?5 ~6 $7")
        XCTAssertEqual(SidebarGitLine.tooltip(projectKey: "/w/api", summary: nil), "/w/api")
        XCTAssertEqual(SidebarGitLine.tooltip(projectKey: nil, summary: busy), "main ↑2 ↓1 +3 !4 ?5 ~6 $7")
        XCTAssertNil(SidebarGitLine.tooltip(projectKey: nil, summary: nil))
    }

    // MARK: - The weights

    /// Every COUNT is heavy and the BRANCH is not: at 10 pt mono a regular sigil run leaves the
    /// colour doing all the work, and a heavy branch would stop the counts reading as one group.
    /// `~conflicted` goes a rung further on IMPORTANCE, in a channel free of the palette.
    ///
    /// Read off the SEGMENT rather than asked for by role: the rung rides along on the same crossing
    /// that decides the run exists, so there is no second table on this side to disagree with.
    func testOnlyTheBranchIsRegularAndOnlyTheConflictIsBold() {
        let weights = Dictionary(
            SidebarGitLine.segments(busy).map { ($0.ink, $0.weight) }, uniquingKeysWith: { first, _ in first },
        )
        XCTAssertEqual(weights[.branch], .regular)
        XCTAssertEqual(weights[.conflicted], .bold)
        for role in GitInk.allCases where role != .branch && role != .conflicted {
            XCTAssertEqual(weights[role], .semibold, "\(role) is a count")
        }
    }

    // MARK: - The compact form and the shed ladder

    /// `↑2 ↓1 !3` → `↑ ↓ !`: the counts go, the ROLES stay, so a squeezed line still says exactly
    /// which states are live. The branch has no sigil and drops out — it truncates instead.
    func testTheCompactFormKeepsTheRolesAndDropsTheBranch() {
        let compact = SidebarGitLine.compactStatus(busy, shedding: 0)
        XCTAssertEqual(compact.map(\.text), ["↑", "↓", "+", "!", "?", "~", "$"])
        XCTAssertEqual(compact.map(\.ink).first, .divergence)
        XCTAssertFalse(compact.contains { $0.ink == .branch })
    }

    /// The ladder's order IS the ranking of "how much does knowing this right now change what I do
    /// next": stash, then divergence, then untracked go first; the WORKTREE survives.
    func testSheddingGivesUpTheLeastUrgentRolesFirst() {
        XCTAssertEqual(SidebarGitLine.compactStatus(busy, shedding: 1).map(\.text), ["↑", "↓", "+", "!", "?", "~"])
        XCTAssertEqual(SidebarGitLine.compactStatus(busy, shedding: 2).map(\.text), ["+", "!", "?", "~"])
        XCTAssertEqual(SidebarGitLine.compactStatus(busy, shedding: 3).map(\.text), ["+", "!", "~"])
    }

    /// `↑` and `↓` are ONE fact about one remote — they leave together, on one rung.
    func testDivergenceShedsAsOneRung() {
        let after = SidebarGitLine.compactStatus(busy, shedding: 2)
        XCTAssertFalse(after.contains { $0.ink == .divergence }, "both arrows leave on the same rung")
    }

    /// A rung the line never had costs NOTHING — otherwise a clean-but-diverged repo would spend its
    /// whole ladder shedding sigils it does not have and lose its real dirt to a phantom.
    func testAnAbsentRoleCostsNoRung() {
        let noStash = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 0, changedCount: 1, staged: 0,
            modified: 1, untracked: 0, conflicted: 0, stash: 0,
        )
        XCTAssertEqual(SidebarGitLine.compactStatus(noStash, shedding: 0).map(\.text), ["↑", "!"])
        // Rung 1 is `$`, which this line never had — so one rung of budget still sheds `↑`.
        XCTAssertEqual(SidebarGitLine.compactStatus(noStash, shedding: 1).map(\.text), ["!"])
    }

    /// The last run standing is NEVER shed. A git line that reports nothing is not a tighter readout,
    /// it is a missing one — so a repo whose only dirt is `↑2` keeps its `↑` however narrow the rail.
    func testTheLastRunSurvivesEveryRung() {
        let onlyAhead = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 0, changedCount: 0,
        )
        XCTAssertEqual(SidebarGitLine.compactStatus(onlyAhead, shedding: 99).map(\.text), ["↑"])
    }
}
