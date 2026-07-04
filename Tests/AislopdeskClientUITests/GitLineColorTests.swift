// GitLineColorTests — pins the sidebar git-line's per-token STATUS colouring (`SlateTabRow.gitLine`): the
// second line of a terminal row folds `PaneGitSummary` into an `AttributedString` whose branch stays MUTED
// (no explicit colour → inherits the row's secondary) while `↑ahead` reads OK-green, `↓behind` info-blue and
// `· N changed` warn-amber (MERIDIAN "colour = state, not ornament"). The rendered TEXT must stay byte-
// identical to `PaneGitSummary.compactLine` so the height/search/fallback (all keyed on the plain subtitle)
// never diverge from the coloured line.
//
// Revert-to-confirm-fail: dropping the colour (returning a plain `AttributedString(g.compactLine!)`) makes
// every run's `foregroundColor` nil → `testDirtyChangedTokenIsWarn` (and the ahead/behind legs) fail on the
// missing token colour. Headless / pure-token — no SCStream/VT/Metal touched.

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class GitLineColorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ThemeStore.shared.apply(.monokaiProClassic) // deterministic status palette (ok/warn/info)
    }

    /// The single colour carried by the run that spells `substring`, or `nil` if that run has no explicit
    /// foreground (so it inherits the row's secondary). Fails the lookup if the substring is absent.
    private func colour(of substring: String, in line: AttributedString) -> Color?? {
        guard let range = line.range(of: substring) else { return .some(nil) }
        return line[range].foregroundColor
    }

    /// The coloured line's plain text is byte-identical to `compactLine` — the height/search/fallback contract.
    func testTextMatchesCompactLine() throws {
        let g = PaneGitSummary(hasRepo: true, branch: "main", ahead: 1, behind: 2, changedCount: 3)
        let line = try XCTUnwrap(SlateTabRow.gitLine(g))
        XCTAssertEqual(String(line.characters), g.compactLine, "coloured text must equal the plain compactLine")
    }

    /// A dirty worktree's `· N changed` token reads warn-amber (the "you have uncommitted work" flag).
    func testDirtyChangedTokenIsWarn() throws {
        let g = PaneGitSummary(hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 3)
        let line = try XCTUnwrap(SlateTabRow.gitLine(g))
        XCTAssertEqual(colour(of: "3 changed", in: line), .some(Slate.Status.warn))
    }

    /// `↑ahead` reads OK-green (outgoing) and `↓behind` reads info-blue (behind upstream) — distinct signals.
    func testAheadIsOkBehindIsInfo() throws {
        let g = PaneGitSummary(hasRepo: true, branch: "main", ahead: 1, behind: 2, changedCount: 0)
        let line = try XCTUnwrap(SlateTabRow.gitLine(g))
        XCTAssertEqual(colour(of: "↑1", in: line), .some(Slate.Status.ok))
        XCTAssertEqual(colour(of: "↓2", in: line), .some(Slate.Status.info))
    }

    /// The branch name carries NO explicit colour — it inherits the row's muted secondary (a branch is
    /// structure, not a status signal). Distinct from `warn`/`ok`/`info` so it can't read as a signal.
    func testBranchIsUncoloured() throws {
        let g = PaneGitSummary(hasRepo: true, branch: "feature-x", ahead: 0, behind: 0, changedCount: 1)
        let line = try XCTUnwrap(SlateTabRow.gitLine(g))
        XCTAssertEqual(colour(of: "feature-x", in: line), .some(Color?.none), "branch inherits secondary")
    }

    /// A CLEAN repo (no ahead/behind/changed) is just the muted branch — no coloured token at all.
    func testCleanRepoHasNoColouredToken() throws {
        let g = PaneGitSummary(hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 0)
        let line = try XCTUnwrap(SlateTabRow.gitLine(g))
        XCTAssertEqual(String(line.characters), "main")
        for run in line.runs {
            XCTAssertNil(run.foregroundColor, "a clean repo's line carries no status colour")
        }
    }

    /// A non-repo cwd yields no git line (the row falls back to its plain cwd subtitle).
    func testNonRepoYieldsNil() {
        let g = PaneGitSummary(hasRepo: false, branch: "", ahead: 0, behind: 0, changedCount: 0)
        XCTAssertNil(SlateTabRow.gitLine(g))
    }
}
#endif
