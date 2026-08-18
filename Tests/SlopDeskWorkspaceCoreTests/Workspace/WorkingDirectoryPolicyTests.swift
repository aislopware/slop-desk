import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the ``WorkingDirectoryPolicy`` CROSSING. The rule — the two keywords, the trim, the repair and
/// which string a new pane's cwd comes from — is `slopdesk_workspace::workdir`; what can only fail on
/// this side is the marshalling: the kind byte both ways, the path written back through the buffer,
/// and the `Source` answer turned back into the string the caller holds.
final class WorkingDirectoryPolicyTests: XCTestCase {
    // MARK: - The kind byte, and the path that comes back through the buffer

    /// Each kind crosses as its own byte and the trimmed path is read out of the door's buffer — the
    /// length, not the raw config's, so a trailing newline does not survive as part of the directory.
    func testEachKindCrossesWithItsTrimmedPath() {
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "  inherit  "), .inherit)
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "\thome\n"), .home)
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "  /tmp/x  "), .path("/tmp/x"))
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "~/work"), .path("~/work"))
    }

    /// A blank value crosses with an EMPTY buffer, which the door still answers a kind for — the case
    /// the `(out, cap) -> needed` convention's `0` would otherwise read as a refusal. It must land on
    /// `.home`, never `.path("")` (which would emit a bogus `cd `).
    func testABlankValueIsHomeRatherThanAnEmptyPath() {
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: ""), .home)
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "   "), .home)
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "\n\t"), .home)
    }

    /// A multi-byte path crosses by UTF-8 LENGTH, not character count: the buffer is sized and sliced
    /// in bytes, so a path whose two counts differ is where an off-by-one would show.
    func testAMultiBytePathSurvivesTheBuffer() {
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: " /Users/me/Ứng dụng "), .path("/Users/me/Ứng dụng"))
    }

    // MARK: - rawConfig: the keywords come back from the crate, the path is our own

    /// The keyword door is the parse door's inverse, so every case round-trips; `.path` short-circuits
    /// it and answers with the string it already holds.
    func testRawConfigRoundTripsThroughBothDoors() {
        XCTAssertEqual(WorkingDirectoryPolicy.inherit.rawConfig, "inherit")
        XCTAssertEqual(WorkingDirectoryPolicy.home.rawConfig, "home")
        XCTAssertEqual(WorkingDirectoryPolicy.path("/tmp/x").rawConfig, "/tmp/x")
        for policy: WorkingDirectoryPolicy in [.inherit, .home, .path("/Users/me/repo"), .path("~/dev")] {
            XCTAssertEqual(
                WorkingDirectoryPolicy(rawConfig: policy.rawConfig), policy,
                "\(policy) must round-trip through rawConfig",
            )
        }
    }

    // MARK: - The Source answer, turned back into a string

    /// The door names WHICH string to use rather than copying one back, so each of its three answers
    /// must select the right one here: the active pane's cwd, the configured path, or neither.
    func testEachSourceSelectsTheStringItNames() {
        XCTAssertEqual(WorkingDirectoryPolicy.inherit.resolve(activePaneCwd: "/Users/me/a"), "/Users/me/a")
        // Nothing to inherit → no `cd`.
        XCTAssertNil(WorkingDirectoryPolicy.inherit.resolve(activePaneCwd: nil))
        // The "no redundant cd" guarantee: `.home` names no directory even when one is available.
        XCTAssertNil(WorkingDirectoryPolicy.home.resolve(activePaneCwd: "/Users/me/somewhere"))
        XCTAssertEqual(WorkingDirectoryPolicy.path("/opt/x").resolve(activePaneCwd: "/Users/me/a"), "/opt/x")
        XCTAssertEqual(WorkingDirectoryPolicy.path("/opt/x").resolve(activePaneCwd: nil), "/opt/x")
    }
}
