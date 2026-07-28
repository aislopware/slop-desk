import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Smoke tests so the target compiles and basic wiring holds. Real PTY spawn + relay
/// + backpressure live in `PTYProcessTests` / `RelayBackpressureTests`.
final class SlopDeskHostSmokeTests: XCTestCase {
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
        // The plain-shell path advertises the libghostty TERM that ``ClaudeCodeProfile`` still
        // owns as the single source of truth (the curated Claude launch is a client-side
        // preset, but the TERM constant lives on the profile) — the client renders with libghostty.
        XCTAssertEqual(env["TERM"], "xterm-ghostty")
        XCTAssertEqual(env["TERM"], HostEnvironment.defaultTerm)
        XCTAssertEqual(
            env["TERM"],
            ClaudeCodeProfile.Term.ghostty.rawValue,
            "plain-shell TERM must share the ClaudeCodeProfile ghostty source of truth",
        )
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["NCURSES_NO_UTF8_ACS"], "1")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    func testCuratedEnvironmentHonoursExplicitTermOverride() {
        // The TERM is a parameter so a caller can select the documented fallback
        // (xterm-256color, #54700) — the constant still lives on ClaudeCodeProfile.Term.
        let env = HostEnvironment.curated(
            parent: ["PATH": "/usr/bin"],
            term: ClaudeCodeProfile.Term.xterm256.rawValue,
        )
        XCTAssertEqual(env["TERM"], "xterm-256color")
    }

    /// TERMINFO / TERMINFO_DIRS must be forwarded to the child when the parent has them — the
    /// host's terminfo probe honours those dirs, so a child that did NOT inherit them would advertise a
    /// `TERM=xterm-ghostty` whose entry its ncurses cannot find (every TUI degrades). When absent, they
    /// must NOT be fabricated.
    func testCuratedEnvironmentForwardsTerminfoSearchPath() {
        let withVars = HostEnvironment.curated(parent: [
            "PATH": "/usr/bin", "TERMINFO": "/opt/ghostty/share/terminfo",
            "TERMINFO_DIRS": "/opt/ghostty/share/terminfo:/usr/share/terminfo",
        ])
        XCTAssertEqual(
            withVars["TERMINFO"],
            "/opt/ghostty/share/terminfo",
            "the child inherits the same terminfo dir the probe validated",
        )
        XCTAssertEqual(withVars["TERMINFO_DIRS"], "/opt/ghostty/share/terminfo:/usr/share/terminfo")
        let withoutVars = HostEnvironment.curated(parent: ["PATH": "/usr/bin"])
        XCTAssertNil(withoutVars["TERMINFO"], "absent in the parent → not fabricated")
        XCTAssertNil(withoutVars["TERMINFO_DIRS"])
    }

    func testLoginArgv0HasLeadingDash() {
        XCTAssertEqual(HostEnvironment.loginArgv0(forShell: "/bin/zsh"), "-zsh")
        XCTAssertEqual(HostEnvironment.loginArgv0(forShell: "/usr/local/bin/fish"), "-fish")
    }

    // MARK: slopdesk-hostd arg parsing → LaunchMode mapping

    func testParseDefaultsToShellLaunchMode() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["slopdesk-hostd"]))
        XCTAssertEqual(parsed.port, 7420)
        XCTAssertNil(parsed.shell)
        XCTAssertEqual(parsed.launchMode, .shell)
    }

    func testParseRetiredClaudeFlagIsUnknownAndRejected() {
        // The curated `claude` launch is not a daemon mode. `--claude`
        // is an UNKNOWN flag → parse returns nil (caller prints usage + exits non-zero).
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "--claude"]))
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "--claude", "--xterm256"]))
    }

    func testParseRetiredXterm256FlagIsUnknownAndRejected() {
        // `--xterm256` is only meaningful with `--claude`; both are retired and unknown flags.
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "--xterm256"]))
    }

    func testParseHelpReturnsNil() {
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "--help"]))
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "-h"]))
    }

    func testParsePortAndShellYieldShellLaunchMode() throws {
        let parsed = try XCTUnwrap(
            HostdArguments.parse(["slopdesk-hostd", "--port", "9001", "--shell", "/bin/bash"]),
        )
        XCTAssertEqual(parsed.port, 9001)
        XCTAssertEqual(parsed.shell, "/bin/bash")
        XCTAssertEqual(parsed.launchMode, .shell)
    }

    // MARK: - -inspector / --transcript (inspector server)

    func testParseDefaultsDisableInspector() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["slopdesk-hostd"]))
        XCTAssertFalse(parsed.inspectorEnabled)
        XCTAssertNil(parsed.transcriptPath)
    }

    func testInspectorIsOnlyEnabledByExplicitFlags() throws {
        // The `--claude` auto-enable is retired: the inspector stands up
        // only on an explicit `--inspector`/`--transcript`. A bare daemon leaves it off.
        let parsed = try XCTUnwrap(HostdArguments.parse(["slopdesk-hostd"]))
        XCTAssertFalse(parsed.inspectorEnabled, "no implicit inspector without an explicit flag")
    }

    func testParseExplicitInspectorFlag() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["slopdesk-hostd", "--inspector"]))
        XCTAssertTrue(parsed.inspectorEnabled)
        XCTAssertEqual(parsed.launchMode, .shell, "--inspector alone does not change launch mode")
    }

    func testParseTranscriptPathImpliesInspector() throws {
        let parsed = try XCTUnwrap(
            HostdArguments.parse(["slopdesk-hostd", "--transcript", "/tmp/session.jsonl"]),
        )
        XCTAssertEqual(parsed.transcriptPath, "/tmp/session.jsonl")
        XCTAssertTrue(parsed.inspectorEnabled, "--transcript implies --inspector")
    }

    func testParseTranscriptMissingValueReturnsNil() {
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "--transcript"]))
    }
}
