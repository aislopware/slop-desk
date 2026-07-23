// ProjectGitStatusLineTests — pins the section header's git segment (`ProjectGitStatusLine`): the
// `__git_ps1` ASCII sigils (`>`ahead `<`behind `+ ! ?` — no arrow dingbats), the ONE-tone rule (every
// count reads the same secondary grey — colour is rationed to the conflict token, the sole state that
// blocks work; the branch inherits the header gray base), the conflict/stash SPLIT (both render as
// separate views, so `=`/`$` must never leak into the attributed main run), and the branch cap (the
// sigil counts are the glanceable payload and may never be truncated away, so the BRANCH
// pre-truncates).
//
// Revert-to-confirm-fail: recolouring a token fails its tone leg; appending conflict/stash to
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
        ThemeStore.shared.apply(.monokaiProClassic) // deterministic palette (secondary/err)
    }

    /// The single colour carried by the run that spells `substring`, or `nil` if that run has no explicit
    /// foreground (so it inherits the header base). Fails the lookup if the substring is absent.
    private func colour(of substring: String, in line: AttributedString) -> Color?? {
        guard let range = line.range(of: substring) else { return .some(nil) }
        return line[range].foregroundColor
    }

    /// Every dirt count wears the SAME secondary tone — one quiet grey, no status rainbow — and the
    /// sigils speak the `__git_ps1` ASCII dialect: `>`ahead, `<`behind, `+`staged, `!`modified,
    /// `?`untracked, in that fixed order.
    func testEveryCountReadsSecondaryInFixedOrder() {
        let g = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 1, behind: 2, changedCount: 6,
            staged: 3, modified: 4, untracked: 5,
        )
        let line = ProjectGitStatusLine.mainLine(g)
        XCTAssertEqual(String(line.characters), "main >1 <2 +3 !4 ?5")
        for token in [">1", "<2", "+3", "!4", "?5"] {
            XCTAssertEqual(colour(of: token, in: line), .some(Slate.Text.secondary), token)
        }
    }

    /// The branch carries NO explicit colour (inherits the header gray base — the section TITLE stays
    /// the anchor, the branch recedes with it).
    func testBranchIsUncoloured() {
        let g = PaneGitSummary(
            hasRepo: true, branch: "feature-x", ahead: 0, behind: 0, changedCount: 1, untracked: 1,
        )
        let line = ProjectGitStatusLine.mainLine(g)
        XCTAssertEqual(colour(of: "feature-x", in: line), .some(Color?.none), "branch inherits the base")
    }

    /// Conflict (`=`) and stash (`$`) render as SEPARATE views (the conflict is the line's one colour;
    /// the stash its own muted tone) — neither may leak into the attributed main run.
    func testConflictAndStashStayOutOfTheMainRun() {
        let g = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 1, behind: 0, changedCount: 3,
            staged: 1, conflicted: 2, stash: 3,
        )
        let text = String(ProjectGitStatusLine.mainLine(g).characters)
        XCTAssertEqual(text, "main >1 +1", "the main run carries branch + ><+!? only")
        XCTAssertFalse(text.contains("="), "conflict renders as its own err-tinted view")
        XCTAssertFalse(text.contains("$"), "stash renders as its own muted view")
    }

    /// A CLEAN repo (no deltas / worktree state) is just the branch — no coloured token, no sigils.
    func testCleanRepoIsJustTheBranch() {
        let g = PaneGitSummary(hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 0)
        let line = ProjectGitStatusLine.mainLine(g)
        XCTAssertEqual(String(line.characters), "main")
        for run in line.runs {
            XCTAssertNil(run.foregroundColor, "a clean repo's line carries no explicit colour")
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
            String(ProjectGitStatusLine.mainLine(g).characters), "feature/…-name-fix >2",
            "the capped branch never eats the sigil suffix",
        )
    }
}
#endif
