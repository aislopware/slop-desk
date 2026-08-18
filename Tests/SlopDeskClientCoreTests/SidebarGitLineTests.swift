// SidebarGitLineTests — the header's GIT DIALECT, pinned where it lives.
//
// The dialect moved to ClientCore with docs/56 stage D: one spelling of the line, read by the Mac's
// `MacGitLineView` and by the tooltip and by every accessibility label. It had NO suite before that
// — it was private to a SwiftUI view — which is exactly why the squeeze ladder could only ever be
// judged by looking at `MacChromeSnapshotRender`'s render. These pins are the arithmetic half;
// the render stays the visual half.

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
    /// read as a readout with no subject.
    func testEmptyBranchReadsAsDetached() {
        let detached = PaneGitSummary(hasRepo: true, branch: "", ahead: 0, behind: 0, changedCount: 0)
        XCTAssertEqual(SidebarGitLine.segments(detached).map(\.text), ["detached"])
    }

    /// The painted line and the SPOKEN one are the same runs joined — they cannot drift.
    func testLineIsTheSegmentsJoined() {
        XCTAssertEqual(SidebarGitLine.line(busy), "main ↑2 ↓1 +3 !4 ?5 ~6 $7")
    }

    // MARK: - The header's two slots

    /// Collapsing folds the git line away — the hidden-row count speaks in its place, and a header
    /// carrying both would say two things on one line.
    func testCollapsedHeaderTradesTheGitLineForTheCount() {
        XCTAssertTrue(SidebarGitLine.detailSegments(collapsed: true, summary: busy).isEmpty)
        XCTAssertFalse(SidebarGitLine.detailSegments(collapsed: false, summary: busy).isEmpty)
        XCTAssertEqual(SidebarGitLine.trailingCount(collapsed: true, count: 3), "3")
        XCTAssertNil(SidebarGitLine.trailingCount(collapsed: false, count: 3))
        XCTAssertNil(SidebarGitLine.trailingCount(collapsed: true, count: 0))
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
    func testOnlyTheBranchIsRegularAndOnlyTheConflictIsBold() {
        XCTAssertEqual(SidebarGitLine.weight(.branch), .regular)
        XCTAssertEqual(SidebarGitLine.weight(.conflicted), .bold)
        for role in GitInk.allCases where role != .branch && role != .conflicted {
            XCTAssertEqual(SidebarGitLine.weight(role), .semibold, "\(role) is a count")
        }
    }

    // MARK: - The compact form

    /// `↑2 ↓1 !3` → `↑ ↓ !`: the counts go, the ROLES stay, so a squeezed line still says exactly
    /// which states are live. The branch has no sigil and drops out — it truncates instead.
    func testCompactStatusKeepsTheRolesAndDropsTheBranch() {
        let compact = SidebarGitLine.compactStatus(SidebarGitLine.segments(busy))
        XCTAssertEqual(compact.map(\.text), ["↑", "↓", "+", "!", "?", "~", "$"])
        XCTAssertEqual(compact.map(\.ink).first, .divergence)
        XCTAssertFalse(compact.contains { $0.ink == .branch })
    }

    // MARK: - The shed ladder

    /// The ladder's order IS the ranking of "how much does knowing this right now change what I do
    /// next": stash, then divergence, then untracked go first; the WORKTREE survives.
    func testSheddingGivesUpTheLeastUrgentRolesFirst() {
        let status = SidebarGitLine.compactStatus(SidebarGitLine.segments(busy))
        XCTAssertEqual(SidebarGitLine.shedding(status, to: 0).map(\.text), ["↑", "↓", "+", "!", "?", "~", "$"])
        XCTAssertEqual(SidebarGitLine.shedding(status, to: 1).map(\.text), ["↑", "↓", "+", "!", "?", "~"])
        XCTAssertEqual(SidebarGitLine.shedding(status, to: 2).map(\.text), ["+", "!", "?", "~"])
        XCTAssertEqual(SidebarGitLine.shedding(status, to: 3).map(\.text), ["+", "!", "~"])
    }

    /// `↑` and `↓` are ONE fact about one remote — they leave together, on one rung.
    func testDivergenceShedsAsOneRung() {
        let status = SidebarGitLine.compactStatus(SidebarGitLine.segments(busy))
        let after = SidebarGitLine.shedding(status, to: 2)
        XCTAssertFalse(after.contains { $0.ink == .divergence }, "both arrows leave on the same rung")
    }

    /// A rung the line never had costs NOTHING — otherwise a clean-but-diverged repo would spend its
    /// whole ladder shedding sigils it does not have and lose its real dirt to a phantom.
    func testAnAbsentRoleCostsNoRung() {
        let noStash = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 0, changedCount: 1, staged: 0,
            modified: 1, untracked: 0, conflicted: 0, stash: 0,
        )
        let status = SidebarGitLine.compactStatus(SidebarGitLine.segments(noStash))
        XCTAssertEqual(status.map(\.text), ["↑", "!"])
        // Rung 1 is `$`, which this line never had — so one rung of budget still sheds `↑`.
        XCTAssertEqual(SidebarGitLine.shedding(status, to: 1).map(\.text), ["!"])
    }

    /// The last run standing is NEVER shed. A git line that reports nothing is not a tighter readout,
    /// it is a missing one — so a repo whose only dirt is `↑2` keeps its `↑` however narrow the rail.
    func testTheLastRunSurvivesEveryRung() {
        let onlyAhead = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 0, changedCount: 0,
        )
        let status = SidebarGitLine.compactStatus(SidebarGitLine.segments(onlyAhead))
        XCTAssertEqual(SidebarGitLine.shedding(status, to: 99).map(\.text), ["↑"])
    }
}
