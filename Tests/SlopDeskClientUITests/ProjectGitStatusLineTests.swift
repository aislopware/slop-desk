// ProjectGitStatusLineTests — pins the section header's git segment (`ProjectGitStatusLine`): the
// per-token STATUS colouring of the main run (branch inherits the header gray base — no explicit
// colour; `↑`ahead/`+`staged ok-green, `↓`behind/`!`modified warn-amber, `?`untracked info-blue),
// the conflict/stash SPLIT (both render as separate views — the conflict pill needs a background
// shape, so `=`/`$` must never leak into the attributed main run), and the branch cap (the sigil
// counts are the glanceable payload and may never be truncated away, so the BRANCH pre-truncates).
//
// Revert-to-confirm-fail: dropping a token colour fails its colour leg; appending conflict/stash to
// `mainLine` fails the split pins; removing the cap fails `testLongBranchCapsInTheMiddle`.
// Headless / pure-token — no SCStream/VT/Metal touched.

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class ProjectGitStatusLineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ThemeStore.shared.apply(.monokaiProClassic) // deterministic status palette (ok/warn/info)
    }

    /// The single colour carried by the run that spells `substring`, or `nil` if that run has no explicit
    /// foreground (so it inherits the header base). Fails the lookup if the substring is absent.
    private func colour(of substring: String, in line: AttributedString) -> Color?? {
        guard let range = line.range(of: substring) else { return .some(nil) }
        return line[range].foregroundColor
    }

    /// Green (ok) = outgoing/index work: `↑`ahead and `+`staged both read OK-green.
    func testAheadAndStagedAreOk() {
        let g = PaneGitSummary(hasRepo: true, branch: "main", ahead: 1, behind: 0, changedCount: 2, staged: 2)
        let line = ProjectGitStatusLine.mainLine(g)
        XCTAssertEqual(colour(of: "↑1", in: line), .some(Slate.Status.ok))
        XCTAssertEqual(colour(of: "+2", in: line), .some(Slate.Status.ok))
    }

    /// Amber (warn) = needs-attention: `↓`behind and `!`modified both read warn-amber.
    func testBehindAndModifiedAreWarn() {
        let g = PaneGitSummary(hasRepo: true, branch: "main", ahead: 0, behind: 2, changedCount: 3, modified: 3)
        let line = ProjectGitStatusLine.mainLine(g)
        XCTAssertEqual(colour(of: "↓2", in: line), .some(Slate.Status.warn))
        XCTAssertEqual(colour(of: "!3", in: line), .some(Slate.Status.warn))
    }

    /// `?`untracked reads info-blue; the branch carries NO explicit colour (inherits the header gray
    /// base — the section TITLE stays the anchor, the branch recedes with it).
    func testUntrackedIsInfoAndBranchIsUncoloured() {
        let g = PaneGitSummary(
            hasRepo: true, branch: "feature-x", ahead: 0, behind: 0, changedCount: 1, untracked: 1,
        )
        let line = ProjectGitStatusLine.mainLine(g)
        XCTAssertEqual(colour(of: "?1", in: line), .some(Slate.Status.info))
        XCTAssertEqual(colour(of: "feature-x", in: line), .some(Color?.none), "branch inherits the base")
    }

    /// Conflict (`=`) and stash (`$`) render as SEPARATE views (the pill needs a background shape;
    /// the stash its own muted tone) — neither may leak into the attributed main run.
    func testConflictAndStashStayOutOfTheMainRun() {
        let g = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 1, behind: 0, changedCount: 3,
            staged: 1, conflicted: 2, stash: 3,
        )
        let text = String(ProjectGitStatusLine.mainLine(g).characters)
        XCTAssertEqual(text, "main ↑1 +1", "the main run carries branch + ↑↓+!? only")
        XCTAssertFalse(text.contains("="), "conflict renders as the pill view, not a main-run token")
        XCTAssertFalse(text.contains("$"), "stash renders as its own muted view")
    }

    /// A CLEAN repo (no deltas / worktree state) is just the branch — no coloured token, no sigils.
    func testCleanRepoIsJustTheBranch() {
        let g = PaneGitSummary(hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 0)
        let line = ProjectGitStatusLine.mainLine(g)
        XCTAssertEqual(String(line.characters), "main")
        for run in line.runs {
            XCTAssertNil(run.foregroundColor, "a clean repo's line carries no status colour")
        }
    }

    /// A detached HEAD (empty branch) reads "detached", never an empty leading token.
    func testDetachedHeadReadsDetached() {
        let g = PaneGitSummary(hasRepo: true, branch: "", ahead: 0, behind: 0, changedCount: 0)
        XCTAssertEqual(String(ProjectGitStatusLine.mainLine(g).characters), "detached")
    }

    /// The branch cap: middle ellipsis at build time, prefix + tail both preserved, and the sigil
    /// suffix intact after it. An 18-char-or-shorter branch passes through verbatim.
    func testLongBranchCapsInTheMiddle() {
        XCTAssertEqual(ProjectGitStatusLine.cappedBranch("main"), "main")
        XCTAssertEqual(
            ProjectGitStatusLine.cappedBranch("feature/very-long-branch-name-fix"),
            "feature/…-name-fix",
            "8 + ellipsis + 9-char tail",
        )
        let g = PaneGitSummary(
            hasRepo: true, branch: "feature/very-long-branch-name-fix",
            ahead: 2, behind: 0, changedCount: 0,
        )
        XCTAssertEqual(
            String(ProjectGitStatusLine.mainLine(g).characters), "feature/…-name-fix ↑2",
            "the capped branch never eats the sigil suffix",
        )
    }
}
#endif
