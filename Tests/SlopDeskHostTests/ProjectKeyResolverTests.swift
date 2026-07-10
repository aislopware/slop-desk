import XCTest
@testable import SlopDeskHost

/// Pins the pure upward walk behind the host-computed By-Project key (wire type 34): nearest
/// ancestor (cwd included) whose `.git` exists wins; no repo anywhere → the normalized cwd
/// verbatim. `isRepoRoot` is injected — no disk in these tests.
final class ProjectKeyResolverTests: XCTestCase {
    func testCwdInsideRepoResolvesToToplevel() {
        let key = ProjectKeyResolver.projectKey(forCwd: "/Users/me/repo/Sources/Deep") {
            $0 == "/Users/me/repo"
        }
        XCTAssertEqual(key, "/Users/me/repo")
    }

    func testCwdAtToplevelResolvesToItself() {
        let key = ProjectKeyResolver.projectKey(forCwd: "/Users/me/repo") { $0 == "/Users/me/repo" }
        XCTAssertEqual(key, "/Users/me/repo")
    }

    func testNoRepoAnywhereFallsBackToCwd() {
        let key = ProjectKeyResolver.projectKey(forCwd: "/Users/me/notes") { _ in false }
        XCTAssertEqual(key, "/Users/me/notes")
    }

    func testNearestAncestorWinsForNestedRepos() {
        // A repo checked out INSIDE another repo (vendored / ThirdParty): the pane groups under the
        // innermost checkout, matching `git rev-parse --show-toplevel` from that cwd.
        let roots: Set = ["/outer", "/outer/vendor/inner"]
        let key = ProjectKeyResolver.projectKey(forCwd: "/outer/vendor/inner/src") { roots.contains($0) }
        XCTAssertEqual(key, "/outer/vendor/inner")
    }

    func testTrailingSlashNormalizesBeforeWalkAndFallback() {
        XCTAssertEqual(
            ProjectKeyResolver.projectKey(forCwd: "/Users/me/repo/") { $0 == "/Users/me/repo" },
            "/Users/me/repo",
            "'/repo/' and '/repo' must latch and emit the SAME key (no phantom re-emission)",
        )
        XCTAssertEqual(
            ProjectKeyResolver.projectKey(forCwd: "/Users/me/notes///") { _ in false },
            "/Users/me/notes",
        )
    }

    func testTopLevelParentIsProbedBeforeFallback() {
        // "/x/y" walks /x/y → /x — the single-component parent must still be probed (a repo checked
        // out at "/x" claims it), then the walk stops at "/" without probing it.
        var probed: [String] = []
        let key = ProjectKeyResolver.projectKey(forCwd: "/x/y") { path in
            probed.append(path)
            return path == "/x"
        }
        XCTAssertEqual(key, "/x")
        XCTAssertEqual(probed, ["/x/y", "/x"])
    }

    func testRootAndRelativeInputsReturnVerbatimWithoutWalking() {
        var probes = 0
        XCTAssertEqual(ProjectKeyResolver.projectKey(forCwd: "/") { _ in probes += 1
            return true
        }, "/")
        XCTAssertEqual(probes, 0, "a bare '/' has no meaningful project — never probed, never a repo")
        XCTAssertEqual(
            ProjectKeyResolver.projectKey(forCwd: "relative/path") { _ in probes += 1
                return true
            },
            "relative/path",
            "a non-absolute cwd (hostile OSC-7) is returned verbatim — validate-then-drop, no walk",
        )
        XCTAssertEqual(probes, 0)
    }
}
