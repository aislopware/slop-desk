// PaneGitSummaryTests — pins the compact git line the sidebar tab row renders (the app's ONE git
// surface now that the inspector tab / auxiliary Git window are removed): the branch / ahead / behind /
// changed-count fold from the wire payload and every `compactLine` shape. Pure value — headless.

import SlopDeskProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

final class PaneGitSummaryTests: XCTestCase {
    private func summary(
        hasRepo: Bool = true, branch: String = "main", ahead: Int = 0, behind: Int = 0, changed: Int = 0,
        staged: Int = 0, modified: Int = 0, untracked: Int = 0, conflicted: Int = 0, stash: Int = 0,
    ) -> PaneGitSummary {
        PaneGitSummary(
            hasRepo: hasRepo, branch: branch, ahead: ahead, behind: behind, changedCount: changed,
            staged: staged, modified: modified, untracked: untracked, conflicted: conflicted, stash: stash,
        )
    }

    /// A clean, tracking branch renders as JUST the branch name — no noise.
    func testCleanRepoIsJustTheBranch() {
        XCTAssertEqual(summary().compactLine, "main")
    }

    /// Ahead/behind deltas append as `↑a ↓b` (each only when non-zero).
    func testAheadBehindDeltas() {
        XCTAssertEqual(summary(ahead: 2).compactLine, "main ↑2")
        XCTAssertEqual(summary(behind: 3).compactLine, "main ↓3")
        XCTAssertEqual(summary(ahead: 1, behind: 4).compactLine, "main ↑1 ↓4")
    }

    /// Each worktree state is a SINGLE sigil + count: `+`staged `!`modified `?`untracked `=`conflicts.
    func testWorktreeSigils() {
        XCTAssertEqual(summary(staged: 2).compactLine, "main +2")
        XCTAssertEqual(summary(modified: 3).compactLine, "main !3")
        XCTAssertEqual(summary(untracked: 1).compactLine, "main ?1")
        XCTAssertEqual(summary(conflicted: 2).compactLine, "main =2")
        // Full order: branch, ↑, ↓, +, !, ?, =, $.
        XCTAssertEqual(
            summary(ahead: 1, behind: 2, staged: 3, modified: 4, untracked: 5, conflicted: 6, stash: 7)
                .compactLine,
            "main ↑1 ↓2 +3 !4 ?5 =6 $7",
        )
    }

    /// The stash depth appends as `$N` (repo-global) — present even on an otherwise clean worktree.
    func testStashSigil() {
        XCTAssertEqual(summary(stash: 1).compactLine, "main $1")
        XCTAssertEqual(summary(modified: 2, stash: 3).compactLine, "main !2 $3")
    }

    /// A detached HEAD (empty branch) reads "detached", never a blank leading token.
    func testDetachedHead() {
        XCTAssertEqual(summary(branch: "", modified: 1).compactLine, "detached !1")
    }

    /// A non-repo cwd renders NOTHING (`nil`) — the rail then falls back to the plain cwd subtitle.
    func testNoRepoRendersNil() {
        XCTAssertNil(summary(hasRepo: false, branch: "").compactLine)
    }

    /// The wire-payload fold derives the porcelain breakdown from the packed `XY` status codes: `0x01`
    /// (` M` — worktree-modified), `0x77` (`??` — untracked), `0x11` (`MM` — staged AND modified, counts
    /// in BOTH), `0x66` (`UU` — a conflict). Branch/ahead/behind + `stashCount` carry over; the
    /// remote/toplevel/file-list are dropped.
    func testPayloadFold() {
        let payload = MetadataCodec.GitStatusPayload(
            hasRepo: true, branch: "feat/x", remoteURL: "git@github.com:a/b.git", repoRoot: "/srv/app",
            ahead: 2, behind: 1, stashCount: 5,
            files: [
                MetadataCodec.GitFileChange(statusCode: 0x01, path: "a.swift"), // " M" modified
                MetadataCodec.GitFileChange(statusCode: 0x77, path: "b.swift"), // "??" untracked
                MetadataCodec.GitFileChange(statusCode: 0x11, path: "c.swift"), // "MM" staged + modified
                MetadataCodec.GitFileChange(statusCode: 0x66, path: "d.swift"), // "UU" conflict
            ],
        )
        let folded = PaneGitSummary(payload: payload)
        XCTAssertEqual(folded, summary(
            branch: "feat/x", ahead: 2, behind: 1, changed: 4,
            staged: 1, modified: 2, untracked: 1, conflicted: 1, stash: 5,
        ))
        XCTAssertEqual(folded.compactLine, "feat/x ↑2 ↓1 +1 !2 ?1 =1 $5")
    }
}
