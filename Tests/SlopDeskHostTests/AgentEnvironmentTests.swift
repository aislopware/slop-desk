import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskHost

/// W10 — the host env wiring for agent detection: the default idiom of the two flags
/// (`SLOPDESK_AGENT_DETECT` default-ON, `SLOPDESK_AGENT_HOOKS` default-OFF) and the
/// `SLOPDESK_SOCKET_PATH` / `SLOPDESK_PANE_ID` PTY-env injection.
final class AgentEnvironmentTests: XCTestCase {
    override func tearDown() {
        EnvConfig.overlay = [:] // the overlay is process-wide; never leak a reaches-consumer override
        super.tearDown()
    }

    // MARK: SLOPDESK_AGENT_DETECT — DEFAULT-ON (`!= "0"`)

    func testAgentDetectDefaultsOn() {
        XCTAssertTrue(HostEnvironment.agentDetectEnabled(environment: [:]), "unset → enabled (default-ON)")
        XCTAssertTrue(HostEnvironment.agentDetectEnabled(environment: ["SLOPDESK_AGENT_DETECT": "1"]))
        XCTAssertTrue(
            HostEnvironment.agentDetectEnabled(environment: ["SLOPDESK_AGENT_DETECT": "anything"]),
            "any value other than exactly \"0\" enables",
        )
    }

    func testAgentDetectOnlyZeroDisables() {
        XCTAssertFalse(
            HostEnvironment.agentDetectEnabled(environment: ["SLOPDESK_AGENT_DETECT": "0"]),
            "only the exact string \"0\" disables",
        )
    }

    // MARK: SLOPDESK_AGENT_HOOKS — DEFAULT-OFF (`== "1"`)

    func testAgentHooksDefaultsOff() {
        XCTAssertFalse(HostEnvironment.agentHooksEnabled(environment: [:]), "unset → disabled (default-OFF)")
        XCTAssertFalse(HostEnvironment.agentHooksEnabled(environment: ["SLOPDESK_AGENT_HOOKS": "0"]))
        XCTAssertFalse(
            HostEnvironment.agentHooksEnabled(environment: ["SLOPDESK_AGENT_HOOKS": "yes"]),
            "only the exact string \"1\" enables",
        )
    }

    func testAgentHooksOnlyOneEnables() {
        XCTAssertTrue(HostEnvironment.agentHooksEnabled(environment: ["SLOPDESK_AGENT_HOOKS": "1"]))
    }

    // MARK: W12 — the settings overlay REACHES the agent gates (via the DEFAULT-arg path)

    /// REACHES-CONSUMER (P1): a Settings toggle folded into ``EnvConfig/overlay`` drives the host's
    /// agent-detection gates when called with NO explicit `environment:` (the production call shape in
    /// `slopdesk-hostd`). The default arg resolves through `HostEnvironment.configEnv` → `EnvConfig`,
    /// so the overlay value lands at the gate. With an EMPTY overlay (and no real env var in the test
    /// runner) the gates keep today's compile-time defaults: detect ON, hooks OFF.
    ///
    /// Guard: only run when the test process does NOT set these as real env vars (a real env var WINS
    /// over the overlay by decision #16, which would mask the overlay path being asserted here).
    func testOverlayReachesAgentGatesViaDefaultArg() throws {
        let realEnv = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            realEnv["SLOPDESK_AGENT_DETECT"] != nil || realEnv["SLOPDESK_AGENT_HOOKS"] != nil,
            "a real env var would win over the overlay (decision #16) — not the path under test",
        )
        EnvConfig.overlay = [:]

        // Empty overlay ⇒ today's defaults via the default-arg path.
        XCTAssertTrue(HostEnvironment.agentDetectEnabled(), "empty overlay ⇒ detect default-ON")
        XCTAssertFalse(HostEnvironment.agentHooksEnabled(), "empty overlay ⇒ hooks default-OFF")

        // A settings override in the overlay reaches the gate (no explicit environment: arg).
        EnvConfig.overlay["SLOPDESK_AGENT_DETECT"] = "0" // OFF
        EnvConfig.overlay["SLOPDESK_AGENT_HOOKS"] = "1" // ON
        XCTAssertFalse(HostEnvironment.agentDetectEnabled(), "overlay SLOPDESK_AGENT_DETECT=0 ⇒ detect OFF")
        XCTAssertTrue(HostEnvironment.agentHooksEnabled(), "overlay SLOPDESK_AGENT_HOOKS=1 ⇒ hooks ON")
    }

    // MARK: socket / pane env injection

    func testCuratedOmitsAgentVarsByDefault() {
        let env = HostEnvironment.curated(parent: [:])
        XCTAssertNil(env["SLOPDESK_SOCKET_PATH"], "no socket exported unless the listener is bound")
        XCTAssertNil(env["SLOPDESK_PANE_ID"])
    }

    func testCuratedExportsSocketAndPaneWhenProvided() {
        let env = HostEnvironment.curated(
            parent: [:],
            agentSocketPath: "/tmp/slopdesk-agent.sock",
            paneID: "conn:7",
        )
        XCTAssertEqual(env["SLOPDESK_SOCKET_PATH"], "/tmp/slopdesk-agent.sock")
        XCTAssertEqual(env["SLOPDESK_PANE_ID"], "conn:7")
    }

    /// The documented daemon-side OSC-133 marks opt-out (`SLOPDESK_OSC133=0`) must be forwarded
    /// into the curated child env — the shim's `.zshrc` reads `${SLOPDESK_OSC133:-1}` in the CHILD,
    /// so the curated allowlist must carry the flag or the opt-out is dead code.
    func testCuratedForwardsOSC133OptOut() {
        let env = HostEnvironment.curated(parent: ["SLOPDESK_OSC133": "0", "HOME": "/Users/x"])
        XCTAssertEqual(env["SLOPDESK_OSC133"], "0", "the daemon-side OSC133 opt-out must reach the child shell")
    }

    /// When the operator did NOT set the flag, curated must not synthesize it — the shim's default-on
    /// branch (`${SLOPDESK_OSC133:-1}` → marks ON) must be preserved.
    func testCuratedOmitsOSC133WhenUnset() {
        let env = HostEnvironment.curated(parent: ["HOME": "/Users/x"])
        XCTAssertNil(env["SLOPDESK_OSC133"], "an unset OSC133 must not be materialized (keep the shim default)")
    }

    func testPaneIDIsTheCompositeKey() {
        let conn = UUID()
        let id = HostServer.paneID(connectionID: conn, channelID: 4)
        XCTAssertEqual(id, "\(conn.uuidString):4", "the pane id is the (connectionID, channelID) composite")
    }

    // MARK: terminal-program identity (TERM_PROGRAM / TERM_PROGRAM_VERSION / CW_TERM)

    /// The curated env must advertise OUR identity unconditionally — `TERM_PROGRAM=slopdesk`,
    /// `CW_TERM=slopdesk` (so Amazon-Q/Fig do NOT `cwterm`-exec mid-`.zshrc`), and a non-empty
    /// `TERM_PROGRAM_VERSION` — regardless of what the parent advertises.
    func testCuratedSetsTerminalProgramIdentity() {
        let env = HostEnvironment.curated(parent: [:])
        XCTAssertEqual(env["TERM_PROGRAM"], "slopdesk")
        XCTAssertEqual(env["CW_TERM"], "slopdesk")
        XCTAssertEqual(env["TERM_PROGRAM_VERSION"], HostEnvironment.buildVersion)
        XCTAssertFalse(env["TERM_PROGRAM_VERSION"]?.isEmpty ?? true, "version must be present + non-empty")
    }

    /// A launcher's `TERM_PROGRAM` (e.g. `Apple_Terminal` / `ghostty`) must NOT leak through to the
    /// child — the child reports `slopdesk`, not the launcher's identity.
    func testCuratedDoesNotMirrorParentTerminalProgram() {
        let env = HostEnvironment.curated(
            parent: ["TERM_PROGRAM": "Apple_Terminal", "TERM_PROGRAM_VERSION": "455", "CW_TERM": "kitty"],
        )
        XCTAssertEqual(env["TERM_PROGRAM"], "slopdesk", "the launcher's TERM_PROGRAM must not leak through")
        XCTAssertEqual(env["TERM_PROGRAM_VERSION"], HostEnvironment.buildVersion)
        XCTAssertEqual(env["CW_TERM"], "slopdesk")
    }
}
