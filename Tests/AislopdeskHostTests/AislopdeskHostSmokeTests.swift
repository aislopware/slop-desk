import XCTest
import AislopdeskProtocol
import AislopdeskTransport
@testable import AislopdeskHost

/// Smoke tests so the target compiles and basic wiring holds. Real PTY spawn + relay
/// + backpressure live in `PTYProcessTests` / `RelayBackpressureTests`.
final class AislopdeskHostSmokeTests: XCTestCase {

    func testPTYProcessInstantiatesWithUnsetFDAndPID() {
        let pty = PTYProcess()
        XCTAssertEqual(pty.masterFD, -1)
        XCTAssertEqual(pty.pid, -1)
    }

    func testHostServerHoldsPortAndStartsEmpty() {
        let server = HostServer(port: 7420)
        XCTAssertEqual(server.port, 7420)
        XCTAssertTrue(server.liveSessionIDs().isEmpty)
        XCTAssertTrue(server.shellPath.hasPrefix("/"))
    }

    func testCuratedEnvironmentHasSaneTerminalDefaults() {
        let env = HostEnvironment.curated(parent: ["PATH": "/usr/bin", "HOME": "/Users/x"])
        // The plain-shell path advertises the SAME libghostty TERM as the Claude Code
        // path (single source of truth) — the client renders with libghostty.
        XCTAssertEqual(env["TERM"], "xterm-ghostty")
        XCTAssertEqual(env["TERM"], HostEnvironment.defaultTerm)
        XCTAssertEqual(env["TERM"], ClaudeCodeProfile.Term.ghostty.rawValue,
                       "plain-shell TERM must share the ClaudeCodeProfile ghostty source of truth")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["NCURSES_NO_UTF8_ACS"], "1")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    func testCuratedEnvironmentHonoursExplicitTermOverride() {
        // The TERM is a parameter so a caller can select the documented fallback
        // (xterm-256color, #54700) symmetrically with ClaudeCodeProfile's toggle.
        let env = HostEnvironment.curated(
            parent: ["PATH": "/usr/bin"],
            term: ClaudeCodeProfile.Term.xterm256.rawValue
        )
        XCTAssertEqual(env["TERM"], "xterm-256color")
    }

    /// R8 #2: TERMINFO / TERMINFO_DIRS must be forwarded to the child when the parent has them — the
    /// host's terminfo probe honours those dirs, so a child that did NOT inherit them would advertise a
    /// `TERM=xterm-ghostty` whose entry its ncurses cannot find (every TUI degrades). When absent, they
    /// must NOT be fabricated.
    func testCuratedEnvironmentForwardsTerminfoSearchPath() {
        let withVars = HostEnvironment.curated(parent: [
            "PATH": "/usr/bin", "TERMINFO": "/opt/ghostty/share/terminfo",
            "TERMINFO_DIRS": "/opt/ghostty/share/terminfo:/usr/share/terminfo",
        ])
        XCTAssertEqual(withVars["TERMINFO"], "/opt/ghostty/share/terminfo",
                       "the child inherits the same terminfo dir the probe validated")
        XCTAssertEqual(withVars["TERMINFO_DIRS"], "/opt/ghostty/share/terminfo:/usr/share/terminfo")
        let withoutVars = HostEnvironment.curated(parent: ["PATH": "/usr/bin"])
        XCTAssertNil(withoutVars["TERMINFO"], "absent in the parent → not fabricated")
        XCTAssertNil(withoutVars["TERMINFO_DIRS"])
    }

    func testLoginArgv0HasLeadingDash() {
        XCTAssertEqual(HostEnvironment.loginArgv0(forShell: "/bin/zsh"), "-zsh")
        XCTAssertEqual(HostEnvironment.loginArgv0(forShell: "/usr/local/bin/fish"), "-fish")
    }

    // MARK: aislopdesk-hostd arg parsing → LaunchMode mapping

    func testParseDefaultsToShellLaunchMode() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["aislopdesk-hostd"]))
        XCTAssertEqual(parsed.port, 7420)
        XCTAssertNil(parsed.shell)
        XCTAssertEqual(parsed.launchMode, .shell)
    }

    func testParseClaudeWithXterm256YieldsClaudeCodeWithXterm256Term() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["aislopdesk-hostd", "--claude", "--xterm256"]))
        XCTAssertEqual(
            parsed.launchMode,
            .claudeCode(ClaudeCodeProfile(term: .xterm256)),
            "--claude --xterm256 must select the claudeCode launch mode with TERM=xterm-256color"
        )
        // Spell the TERM out explicitly so a regression in the toggle is obvious.
        guard case let .claudeCode(profile) = parsed.launchMode else {
            return XCTFail("expected claudeCode launch mode")
        }
        XCTAssertEqual(profile.term, .xterm256)
        XCTAssertEqual(profile.term.rawValue, "xterm-256color")
    }

    func testParseClaudeWithoutXterm256DefaultsToGhosttyTerm() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["aislopdesk-hostd", "--claude"]))
        XCTAssertEqual(parsed.launchMode, .claudeCode(ClaudeCodeProfile(term: .ghostty)))
    }

    func testParseXterm256WithoutClaudeStaysShell() throws {
        // --xterm256 only has meaning with --claude; on its own it is a no-op.
        let parsed = try XCTUnwrap(HostdArguments.parse(["aislopdesk-hostd", "--xterm256"]))
        XCTAssertEqual(parsed.launchMode, .shell)
    }

    func testParseHelpReturnsNil() {
        XCTAssertNil(HostdArguments.parse(["aislopdesk-hostd", "--help"]))
        XCTAssertNil(HostdArguments.parse(["aislopdesk-hostd", "-h"]))
    }

    func testParsePortAndShellAlongsideClaude() throws {
        let parsed = try XCTUnwrap(
            HostdArguments.parse(["aislopdesk-hostd", "--port", "9001", "--shell", "/bin/bash", "--claude"])
        )
        XCTAssertEqual(parsed.port, 9001)
        XCTAssertEqual(parsed.shell, "/bin/bash")
        XCTAssertEqual(parsed.launchMode, .claudeCode(ClaudeCodeProfile(term: .ghostty)))
    }

    // MARK: --inspector / --transcript (inspector server)

    func testParseDefaultsDisableInspector() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["aislopdesk-hostd"]))
        XCTAssertFalse(parsed.inspectorEnabled)
        XCTAssertNil(parsed.transcriptPath)
    }

    func testParseClaudeAutoEnablesInspector() throws {
        // --claude implies the inspector (it observes a claude session).
        let parsed = try XCTUnwrap(HostdArguments.parse(["aislopdesk-hostd", "--claude"]))
        XCTAssertTrue(parsed.inspectorEnabled, "--claude auto-enables the inspector")
    }

    func testParseExplicitInspectorFlag() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["aislopdesk-hostd", "--inspector"]))
        XCTAssertTrue(parsed.inspectorEnabled)
        XCTAssertEqual(parsed.launchMode, .shell, "--inspector alone does not change launch mode")
    }

    func testParseTranscriptPathImpliesInspector() throws {
        let parsed = try XCTUnwrap(
            HostdArguments.parse(["aislopdesk-hostd", "--transcript", "/tmp/session.jsonl"])
        )
        XCTAssertEqual(parsed.transcriptPath, "/tmp/session.jsonl")
        XCTAssertTrue(parsed.inspectorEnabled, "--transcript implies --inspector")
    }

    func testParseTranscriptMissingValueReturnsNil() {
        XCTAssertNil(HostdArguments.parse(["aislopdesk-hostd", "--transcript"]))
    }
}
