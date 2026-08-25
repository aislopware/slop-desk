import XCTest
@testable import SlopDeskHost

/// Smoke tests so the target compiles and basic wiring holds. Real PTY spawn + relay
/// + backpressure live in `PTYProcessTests` / `MuxChannelSessionBackpressureTests`.
final class SlopDeskHostSmokeTests: XCTestCase {
    func testPTYProcessInstantiatesWithUnsetFDAndPID() {
        let pty = unattachedPTY()
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
        // The client renders with libghostty, so a spawned shell advertises the native ghostty TERM.
        XCTAssertEqual(env["TERM"], "xterm-ghostty")
        XCTAssertEqual(env["TERM"], HostEnvironment.defaultTerm)
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["NCURSES_NO_UTF8_ACS"], "1")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    /// The TERM resolution crosses the door and comes back with both halves of its answer.
    ///
    /// The rule itself — the search order, the two on-disk layouts, the `infocmp` authority — is
    /// `slopdesk-probe`'s and is pinned there. What is pinned HERE is the crossing: a name in, a
    /// name and a `fellBack` flag out, and the short-circuit that a request which IS the fallback is
    /// authoritative rather than a fallback (nothing gets logged for it).
    func testTheTermResolutionCrossesTheDoorWithBothHalvesOfItsAnswer() {
        let explicit = HostEnvironment.resolveTerm(requested: HostEnvironment.fallbackTerm)
        XCTAssertEqual(explicit.term, HostEnvironment.fallbackTerm)
        XCTAssertFalse(explicit.fellBack, "the fallback asked for by name is a choice, not a fallback")

        let absent = HostEnvironment.resolveTerm(requested: "xterm-nothing-ships-this")
        XCTAssertEqual(absent.term, HostEnvironment.fallbackTerm)
        XCTAssertTrue(absent.fellBack, "an unresolvable entry must report itself so the log says so")
    }

    func testCuratedEnvironmentHonoursExplicitTermOverride() {
        // The TERM is a parameter so a caller can select the documented fallback
        // (xterm-256color, #54700), which is the one the resolution lands on.
        let env = HostEnvironment.curated(
            parent: ["PATH": "/usr/bin"],
            term: HostEnvironment.fallbackTerm,
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

    // MARK: HostdArguments — the FACE, not the grammar

    // Which flags exist, which take values, which are refused, and what the usage line says are
    // `slopdesk-hostlaunch`'s tests — the declaration is there and asserting it again here would be
    // the second spelling this port removed. What is left to check is the MARSHALLING: that the blob
    // this side decodes carries every field, that a refusal survives the status byte, and that an
    // argument holding a space is not cut in half by the NUL framing.

    func testParseDecodesEveryFieldOffTheBlob() throws {
        let bare = try XCTUnwrap(HostdArguments.parse(["slopdesk-hostd"]))
        XCTAssertEqual(bare.port, HostdArguments.defaultPort)
        XCTAssertNil(bare.shell)
        XCTAssertFalse(bare.inspectorEnabled)
        XCTAssertNil(bare.transcriptPath)

        let full = try XCTUnwrap(HostdArguments.parse([
            "slopdesk-hostd", "--port", "9001", "--shell", "/bin/bash",
            "--transcript", "/tmp/session.jsonl",
        ]))
        XCTAssertEqual(full.port, 9001)
        XCTAssertEqual(full.shell, "/bin/bash")
        XCTAssertEqual(full.transcriptPath, "/tmp/session.jsonl")
        XCTAssertTrue(full.inspectorEnabled, "--transcript implies --inspector")
    }

    func testAnArgumentWithASpaceSurvivesTheNULFraming() throws {
        let parsed = try XCTUnwrap(
            HostdArguments.parse(["slopdesk-hostd", "--shell", "/opt/My Shells/zsh"]),
        )
        XCTAssertEqual(parsed.shell, "/opt/My Shells/zsh")
    }

    func testARefusalReadsAsNilRatherThanADefaultedParse() {
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "--help"]))
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "--claude"]))
        XCTAssertNil(HostdArguments.parse(["slopdesk-hostd", "--transcript"]))
    }

    func testTheUsageLineIsRenderedForTheProgramItIsGiven() {
        let text = HostdArguments.usage(programName: "slopdesk-hostd")
        XCTAssertTrue(text.hasPrefix("usage: slopdesk-hostd "), text)
        XCTAssertTrue(text.contains("--transcript"), text)
    }

    func testTheDefaultPortIsAskedForRatherThanSpelled() {
        // The door's number, whatever it is — asserting 7420 here would re-introduce exactly the
        // transcription the door removed. What matters is that it is a real, non-ephemeral port,
        // and that a bare parse lands on it rather than on a literal of its own.
        XCTAssertNotEqual(HostdArguments.defaultPort, 0)
        XCTAssertEqual(HostdArguments.parse(["slopdesk-hostd"])?.port, HostdArguments.defaultPort)
    }
}
