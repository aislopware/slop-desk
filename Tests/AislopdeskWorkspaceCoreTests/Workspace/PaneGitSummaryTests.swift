// PaneGitSummaryTests — pins the compact git line the sidebar tab row renders (the app's ONE git
// surface now that the inspector tab / auxiliary Git window are removed): the branch / ahead / behind /
// changed-count fold from the wire payload and every `compactLine` shape. Pure value — headless.

import AislopdeskProtocol
import XCTest
@testable import AislopdeskWorkspaceCore

final class PaneGitSummaryTests: XCTestCase {
    private func summary(
        hasRepo: Bool = true, branch: String = "main", ahead: Int = 0, behind: Int = 0, changed: Int = 0,
    ) -> PaneGitSummary {
        PaneGitSummary(hasRepo: hasRepo, branch: branch, ahead: ahead, behind: behind, changedCount: changed)
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

    /// The dirty count appends as `· N changed` after the branch/deltas.
    func testChangedCount() {
        XCTAssertEqual(summary(changed: 3).compactLine, "main · 3 changed")
        XCTAssertEqual(summary(ahead: 1, behind: 2, changed: 5).compactLine, "main ↑1 ↓2 · 5 changed")
    }

    /// A detached HEAD (empty branch) reads "detached", never a blank leading token.
    func testDetachedHead() {
        XCTAssertEqual(summary(branch: "", changed: 1).compactLine, "detached · 1 changed")
    }

    /// A non-repo cwd renders NOTHING (`nil`) — the rail then falls back to the plain cwd subtitle.
    func testNoRepoRendersNil() {
        XCTAssertNil(summary(hasRepo: false, branch: "").compactLine)
    }

    /// The wire-payload fold: branch/ahead/behind carry over, `changedCount` is the FILE COUNT (the
    /// rail never needs the per-file list), and the remote/toplevel are dropped.
    func testPayloadFold() {
        let payload = MetadataCodec.GitStatusPayload(
            hasRepo: true, branch: "feat/x", remoteURL: "git@github.com:a/b.git", repoRoot: "/srv/app",
            ahead: 2, behind: 1,
            files: [
                MetadataCodec.GitFileChange(statusCode: 0x01, path: "a.swift"),
                MetadataCodec.GitFileChange(statusCode: 0x77, path: "b.swift"),
            ],
        )
        let folded = PaneGitSummary(payload: payload)
        XCTAssertEqual(folded, summary(branch: "feat/x", ahead: 2, behind: 1, changed: 2))
        XCTAssertEqual(folded.compactLine, "feat/x ↑2 ↓1 · 2 changed")
    }
}
