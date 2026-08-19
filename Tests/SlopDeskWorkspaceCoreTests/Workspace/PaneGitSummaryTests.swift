// PaneGitSummaryTests — pins the WIRE FOLD: the branch / ahead / behind / stash carry-over and the
// porcelain breakdown derived from the packed `XY` status codes. Pure value — headless.
//
// It used to pin a `compactLine` renderer too, and that renderer is gone (docs/56 increment 45): the
// rail's git line is `SidebarGitLine.segments`, which spells a conflict `~` where the dead one spelled
// it `=`. Twelve assertions were the ONLY thing keeping the wrong spelling compiling — a second
// renderer for one surface, kept alive by its own tests. What is left here is the fold, which is
// what every renderer reads.

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
        XCTAssertEqual(PaneGitSummary(payload: payload), summary(
            branch: "feat/x", ahead: 2, behind: 1, changed: 4,
            staged: 1, modified: 2, untracked: 1, conflicted: 1, stash: 5,
        ))
    }

    /// A non-repo cwd folds to `hasRepo: false` — every renderer keys its fallback off that flag.
    func testNoRepoFoldsToNoRepo() {
        let payload = MetadataCodec.GitStatusPayload(
            hasRepo: false, branch: "", remoteURL: "", repoRoot: "",
            ahead: 0, behind: 0, stashCount: 0, files: [],
        )
        XCTAssertFalse(PaneGitSummary(payload: payload).hasRepo)
    }
}
