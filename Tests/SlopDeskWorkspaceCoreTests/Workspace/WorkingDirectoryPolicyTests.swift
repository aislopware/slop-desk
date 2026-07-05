import XCTest
@testable import SlopDeskWorkspaceCore

/// E3 WI-2 (ES-E3-2): pins the pure `working-directory` policy — ``WorkingDirectoryPolicy`` — covering
/// the `init(rawConfig:)` ↔ `rawConfig` round-trip (the persisted config string) and
/// `resolve(activePaneCwd:)` per case.
///
/// The load-bearing guarantees: `inherit` carries the active pane's cwd through (the "Same as Current"
/// behaviour); `home` resolves to **`nil`** so the store sends NO redundant `cd` into a login shell that
/// already starts at `$HOME`; a config value that is neither `inherit` nor `home` becomes a fixed `path`.
/// Validate-then-repair: an empty / whitespace value is `home`, never a trap. Pure value type — no store,
/// no I/O.
final class WorkingDirectoryPolicyTests: XCTestCase {
    // MARK: - init(rawConfig:) decode

    func testInitDecodesInherit() {
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "inherit"), .inherit)
    }

    func testInitDecodesHome() {
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "home"), .home)
    }

    func testInitEmptyOrWhitespaceRepairsToHome() {
        // Validate-then-repair: a blank / whitespace-only stored value must NOT trap and must NOT become a
        // `.path("")` (which would emit a bogus `cd `); it falls back to `.home`.
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: ""), .home)
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "   "), .home)
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "\n\t"), .home)
    }

    func testInitDecodesArbitraryPath() {
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "/Users/me/project"), .path("/Users/me/project"))
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "~/work"), .path("~/work"))
    }

    func testInitTrimsThePathAndTheKeywords() {
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "  inherit  "), .inherit)
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "\thome\n"), .home)
        XCTAssertEqual(WorkingDirectoryPolicy(rawConfig: "  /tmp/x  "), .path("/tmp/x"))
    }

    // MARK: - rawConfig encode + round-trip

    func testRawConfigPerCase() {
        XCTAssertEqual(WorkingDirectoryPolicy.inherit.rawConfig, "inherit")
        XCTAssertEqual(WorkingDirectoryPolicy.home.rawConfig, "home")
        XCTAssertEqual(WorkingDirectoryPolicy.path("/tmp/x").rawConfig, "/tmp/x")
    }

    func testRawConfigRoundTrips() {
        for policy: WorkingDirectoryPolicy in [.inherit, .home, .path("/Users/me/repo"), .path("~/dev")] {
            XCTAssertEqual(
                WorkingDirectoryPolicy(rawConfig: policy.rawConfig), policy,
                "\(policy) must round-trip through rawConfig",
            )
        }
    }

    // MARK: - resolve(activePaneCwd:)

    func testInheritCarriesTheActiveCwd() {
        XCTAssertEqual(WorkingDirectoryPolicy.inherit.resolve(activePaneCwd: "/Users/me/a"), "/Users/me/a")
    }

    func testInheritWithNoActiveCwdResolvesNil() {
        // The active pane has no known cwd yet (never reported one) → nothing to inherit → no `cd`.
        XCTAssertNil(WorkingDirectoryPolicy.inherit.resolve(activePaneCwd: nil))
    }

    func testHomeAlwaysResolvesNilEvenWithAnActiveCwd() {
        // The crucial "no redundant cd" guarantee: even when the active pane HAS a cwd, `.home` ignores it
        // and resolves nil (the login shell already opens at $HOME).
        XCTAssertNil(WorkingDirectoryPolicy.home.resolve(activePaneCwd: "/Users/me/somewhere"))
        XCTAssertNil(WorkingDirectoryPolicy.home.resolve(activePaneCwd: nil))
    }

    func testPathIgnoresTheActiveCwd() {
        // A fixed path is independent of where the active pane sits.
        XCTAssertEqual(WorkingDirectoryPolicy.path("/opt/x").resolve(activePaneCwd: "/Users/me/a"), "/opt/x")
        XCTAssertEqual(WorkingDirectoryPolicy.path("/opt/x").resolve(activePaneCwd: nil), "/opt/x")
    }
}
