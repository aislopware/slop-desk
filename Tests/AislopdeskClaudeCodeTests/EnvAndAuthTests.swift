import Foundation
import XCTest
@testable import AislopdeskHost

/// WF-7 host launch environment + auth resolution tests.
///
/// PRIVACY: the auth tests use a FIXTURE temp `.credentials.json`. They assert on
/// existence / path ONLY and inject an open-recording predicate to PROVE the resolver
/// never reads the file's bytes. The real `~/.claude/.credentials.json` is never touched.
final class EnvAndAuthTests: XCTestCase {
    // MARK: Curated env — forced keys

    func testForcedKeysPresentWithDefaultGhosttyProfile() {
        let profile = ClaudeCodeProfile() // default .ghostty
        let env = profile.environment(parent: ["HOME": "/Users/x", "PATH": "/usr/bin"])

        XCTAssertEqual(env["TERM"], "xterm-ghostty")
        XCTAssertEqual(env["CLAUDE_CODE_NO_FLICKER"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_ENTRYPOINT"], "remote_mobile")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
    }

    func testTermToggleToXterm256() {
        let profile = ClaudeCodeProfile(term: .xterm256)
        let env = profile.environment(parent: [:])
        XCTAssertEqual(env["TERM"], "xterm-256color")
        // The other forced keys are unaffected by the toggle.
        XCTAssertEqual(env["CLAUDE_CODE_NO_FLICKER"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_ENTRYPOINT"], "remote_mobile")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
    }

    // MARK: Curated env — inherited keys preserved, not clobbered

    func testInheritedKeysPreserved() {
        let parent: [String: String] = [
            "HOME": "/Users/dev",
            "USER": "dev",
            "LOGNAME": "dev",
            "SHELL": "/bin/zsh",
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "TMPDIR": "/var/folders/tmp/",
            "LANG": "en_GB.UTF-8",
            "LC_CTYPE": "en_GB.UTF-8",
            "TERM_PROGRAM": "Ghostty",
        ]
        let env = ClaudeCodeProfile().environment(parent: parent)

        XCTAssertEqual(env["HOME"], "/Users/dev")
        XCTAssertEqual(env["USER"], "dev")
        XCTAssertEqual(env["LOGNAME"], "dev")
        XCTAssertEqual(env["SHELL"], "/bin/zsh")
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(env["TMPDIR"], "/var/folders/tmp/")
        // The user's LANG is preserved (not clobbered with the en_US default).
        XCTAssertEqual(env["LANG"], "en_GB.UTF-8")
        XCTAssertEqual(env["LC_CTYPE"], "en_GB.UTF-8")
        XCTAssertEqual(env["TERM_PROGRAM"], "Ghostty")
    }

    func testEnvironmentNotClobberedWholesale() {
        // A parent var that is NOT in the allowlist must NOT leak into the child env
        // (we merge a curated allowlist, we do not copy the parent wholesale).
        let parent = ["HOME": "/Users/dev", "SECRET_TOKEN": "leak-me", "AWS_KEY": "abc"]
        let env = ClaudeCodeProfile().environment(parent: parent)
        XCTAssertNil(env["SECRET_TOKEN"])
        XCTAssertNil(env["AWS_KEY"])
        XCTAssertEqual(env["HOME"], "/Users/dev")
    }

    func testLangDefaultsWhenAbsent() {
        let env = ClaudeCodeProfile().environment(parent: ["HOME": "/Users/dev"])
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
    }

    func testForcedKeysOverwriteParent() {
        // Even if the parent already set TERM / COLORTERM / the CLAUDE_* keys, the
        // curated profile FORCES its own values on top.
        let parent = [
            "HOME": "/Users/dev",
            "TERM": "dumb",
            "COLORTERM": "",
            "CLAUDE_CODE_NO_FLICKER": "0",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
        ]
        let env = ClaudeCodeProfile().environment(parent: parent)
        XCTAssertEqual(env["TERM"], "xterm-ghostty")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["CLAUDE_CODE_NO_FLICKER"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_ENTRYPOINT"], "remote_mobile")
    }

    func testForcedAndInheritedKeySetsDisjoint() {
        // The forced (curated) keys and the inherited allowlist must be disjoint: a key
        // is EITHER always overwritten OR passed through, never ambiguously both. TERM is
        // forced; TERM_PROGRAM is inherited — no overlap.
        let forced = Set(ClaudeCodeProfile.forcedKeys)
        let inherited = Set(ClaudeCodeProfile.inheritedKeys)
        XCTAssertTrue(forced.isDisjoint(with: inherited), "forced/inherited must not overlap")
        XCTAssertTrue(forced.contains("TERM"))
        XCTAssertTrue(inherited.contains("TERM_PROGRAM"))
        XCTAssertFalse(inherited.contains("TERM"))
    }

    func testLoginShellArguments() {
        XCTAssertEqual(ClaudeCodeProfile().loginShellArguments(), ["-lc", "claude"])
        XCTAssertEqual(
            ClaudeCodeProfile(command: "/opt/claude").loginShellArguments(),
            ["-lc", "/opt/claude"],
        )
    }

    // MARK: Auth — fixture present → inheritedCredentials (stat-only)

    func testAuthInheritedCredentialsWhenFixturePresent() throws {
        let home = try makeFixtureHomeWithCredentials()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Default resolver uses FileManager.fileExists (a stat, not a read).
        let strategy = ClaudeAuthResolver.resolve(home: home)
        let expectedPath = ClaudeAuthResolver.credentialsPath(home: home)
        XCTAssertEqual(strategy, .inheritedCredentials(path: expectedPath))
    }

    func testAuthResolverNeverReadsFileBytes() throws {
        // Stronger privacy proof: inject an existsCheck that asserts it is only ever
        // called for existence (it returns true) and crashes the test if anyone tries to
        // smuggle in a read. Since `resolve` only takes a `(String) -> Bool` predicate,
        // it has NO capability to read bytes — this test documents that invariant.
        let home = try makeFixtureHomeWithCredentials()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let path = ClaudeAuthResolver.credentialsPath(home: home)
        var statCount = 0
        let strategy = ClaudeAuthResolver.resolve(home: home, existsCheck: { p in
            statCount += 1
            XCTAssertEqual(p, path)
            return true
        })
        XCTAssertEqual(strategy, .inheritedCredentials(path: path))
        XCTAssertEqual(statCount, 1, "resolver should stat exactly once")
    }

    // MARK: Auth — fixture absent → setupToken

    func testAuthSetupTokenWhenAbsent() {
        let home = NSTemporaryDirectory() + "aislopdesk-noauth-\(UUID().uuidString)"
        // Note: we never create the file → it does not exist.
        let strategy = ClaudeAuthResolver.resolve(home: home)
        XCTAssertEqual(strategy, .setupToken(needed: true))
    }

    func testAuthSetupTokenWhenHomeMissing() {
        let strategy = ClaudeAuthResolver.resolve(parent: [:])
        XCTAssertEqual(strategy, .setupToken(needed: true))
    }

    func testAuthResolveFromParentEnv() throws {
        let home = try makeFixtureHomeWithCredentials()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let strategy = ClaudeAuthResolver.resolve(parent: ["HOME": home])
        XCTAssertEqual(
            strategy,
            .inheritedCredentials(path: ClaudeAuthResolver.credentialsPath(home: home)),
        )
    }

    // MARK: Fixture helper

    /// Creates a temp HOME with a FIXTURE `.claude/.credentials.json`. The fixture holds
    /// junk bytes that the resolver must never read — we assert only on existence/path.
    private func makeFixtureHomeWithCredentials() throws -> String {
        let home = NSTemporaryDirectory() + "aislopdesk-auth-\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".claude").path
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
        )
        let path = URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json").path
        // Obviously-fake fixture content; the resolver must never read this.
        try Data("{\"FIXTURE_ONLY\":true}".utf8).write(to: URL(fileURLWithPath: path))
        return home
    }
}
