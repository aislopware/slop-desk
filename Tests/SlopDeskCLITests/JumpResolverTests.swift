import SlopDeskCLICore
import SlopDeskWorkspaceCore
import XCTest

// `JumpResolver` tests.
//
// The PURE `slopdesk jump` path resolver: frecency rank (query jumps), the `$HOME`↔last-jump-source
// toggle (no-query jumps), and the `--no-cd` non-committing preview. No socket, no store, no GUI — the
// resolver is exercised directly with constructed `FolderEntry` values and a fixed clock.
//
// The expectations are derived INDEPENDENTLY of the resolver (a hand-reasoned frecency order + the
// documented toggle semantics), so a regression — e.g. ranking by raw count, or a `--no-cd` preview that
// wrongly advances the toggle — FAILS here (revert-to-confirm-fail).

final class JumpResolverTests: XCTestCase {
    /// A fixed clock so the recency buckets are deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let home = "/Users/me"

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    // MARK: - Query jumps (frecency rank)

    func testQueryPicksHighestFrecencyMatch() throws {
        let entries = [
            FolderEntry(path: "/work/repo-old", accessCount: 1, lastAccess: daysAgo(40)), // 1 × stale(1) = 1
            FolderEntry(path: "/work/repo-main", accessCount: 10, lastAccess: now), // 10 × hour(16) = 160
        ]
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: "repo", entries: entries, now: now, homePath: home,
            currentCwd: "/somewhere", lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(r.path, "/work/repo-main")
    }

    /// Recency must outrank raw visit count — the defining property of *frecency*. A recently-visited
    /// low-count folder beats an old high-count one; a count-only resolver would invert this and FAIL.
    func testQueryRecencyOutranksRawCount() throws {
        let entries = [
            FolderEntry(path: "/old/repo", accessCount: 50, lastAccess: daysAgo(40)), // 50 × stale(1) = 50
            FolderEntry(path: "/recent/repo", accessCount: 5, lastAccess: now), // 5 × hour(16) = 80
        ]
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: "repo", entries: entries, now: now, homePath: home,
            currentCwd: nil, lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(r.path, "/recent/repo")
    }

    func testQueryNoMatchReturnsNil() {
        let entries = [FolderEntry(path: "/work/repo", accessCount: 3, lastAccess: now)]
        XCTAssertNil(JumpResolver.resolve(
            query: "zzz", entries: entries, now: now, homePath: home,
            currentCwd: nil, lastJumpSource: nil, changeDirectory: true,
        ))
    }

    func testQueryCaseInsensitiveSubstring() throws {
        let entries = [FolderEntry(path: "/work/Repo-Main", accessCount: 3, lastAccess: now)]
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: "REPO-MAIN", entries: entries, now: now, homePath: home,
            currentCwd: nil, lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(r.path, "/work/Repo-Main")
    }

    func testQueryJumpLeavesToggleSourceUnchanged() throws {
        // A query jump does not participate in the home toggle — the persisted source is carried through.
        let entries = [FolderEntry(path: "/work/repo", accessCount: 3, lastAccess: now)]
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: "repo", entries: entries, now: now, homePath: home,
            currentCwd: "/elsewhere", lastJumpSource: "/keep/me", changeDirectory: true,
        ))
        XCTAssertEqual(r.path, "/work/repo")
        XCTAssertEqual(r.lastJumpSource, "/keep/me")
    }

    func testBlankQueryFallsToToggleNotMatch() throws {
        // A whitespace-only query is treated as ABSENT → the no-query toggle, not a (failed) match.
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: "   ", entries: [], now: now, homePath: home,
            currentCwd: "/work/foo", lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(r.path, home)
        XCTAssertEqual(r.lastJumpSource, "/work/foo")
    }

    // MARK: - No-query toggle ($HOME ↔ last jump source)

    func testAwayFromHomeGoesHomeAndRecordsSource() throws {
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: "/work/foo", lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(r.path, home)
        XCTAssertEqual(r.lastJumpSource, "/work/foo") // remembered where we left
    }

    func testAtHomeReturnsToSourceKeepingIt() throws {
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: home, lastJumpSource: "/work/foo", changeDirectory: true,
        ))
        XCTAssertEqual(r.path, "/work/foo")
        XCTAssertEqual(r.lastJumpSource, "/work/foo") // kept, so the toggle keeps alternating
    }

    func testAtHomeNoSourceFallsToTopFrecency() throws {
        let entries = [
            FolderEntry(path: "/b/low", accessCount: 1, lastAccess: daysAgo(40)),
            FolderEntry(path: "/a/top", accessCount: 9, lastAccess: now),
        ]
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: entries, now: now, homePath: home,
            currentCwd: home, lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(r.path, "/a/top")
        XCTAssertNil(r.lastJumpSource)
    }

    func testNoSourceNoEntriesStaysHome() throws {
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: home, lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(r.path, home)
        XCTAssertNil(r.lastJumpSource)
    }

    func testUnknownCwdUsesSource() throws {
        // cwd never seen (nil) → cannot do the precise toggle → return to the recorded source.
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: nil, lastJumpSource: "/work/foo", changeDirectory: true,
        ))
        XCTAssertEqual(r.path, "/work/foo")
    }

    func testBlankCwdTreatedAsUnknown() throws {
        let entries = [FolderEntry(path: "/a/top", accessCount: 9, lastAccess: now)]
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: entries, now: now, homePath: home,
            currentCwd: "   ", lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(r.path, "/a/top") // blank cwd → unknown → top frecency
    }

    func testToggleRoundTripAlternates() throws {
        // Step 1: away from home → home, source = /work/foo.
        let s1 = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: "/work/foo", lastJumpSource: nil, changeDirectory: true,
        ))
        XCTAssertEqual(s1.path, home)
        XCTAssertEqual(s1.lastJumpSource, "/work/foo")

        // Step 2: now at home (post-cd) with the recorded source → back to /work/foo.
        let s2 = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: home, lastJumpSource: s1.lastJumpSource, changeDirectory: true,
        ))
        XCTAssertEqual(s2.path, "/work/foo")
        XCTAssertEqual(s2.lastJumpSource, "/work/foo")

        // Step 3: back at /work/foo → home again (toggles).
        let s3 = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: "/work/foo", lastJumpSource: s2.lastJumpSource, changeDirectory: true,
        ))
        XCTAssertEqual(s3.path, home)
    }

    // MARK: - --no-cd (non-committing preview)

    func testNoCdPreviewResolvesButDoesNotAdvanceSource() throws {
        // Same inputs as `testAwayFromHomeGoesHomeAndRecordsSource`, but a `--no-cd` preview
        // (changeDirectory: false) must NOT advance the toggle source — it stays nil.
        let r = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: "/work/foo", lastJumpSource: nil, changeDirectory: false,
        ))
        XCTAssertEqual(r.path, home) // still resolves the path to print
        XCTAssertNil(r.lastJumpSource) // but the toggle is untouched (no jump happened)
    }

    func testCommittedJumpAdvancesSourceWhereaPreviewDoesNot() throws {
        let committed = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: "/work/foo", lastJumpSource: nil, changeDirectory: true,
        ))
        let preview = try XCTUnwrap(JumpResolver.resolve(
            query: nil, entries: [], now: now, homePath: home,
            currentCwd: "/work/foo", lastJumpSource: nil, changeDirectory: false,
        ))
        XCTAssertEqual(committed.path, preview.path) // identical resolution
        XCTAssertEqual(committed.lastJumpSource, "/work/foo") // committed advances
        XCTAssertNil(preview.lastJumpSource) // preview does not
    }
}
