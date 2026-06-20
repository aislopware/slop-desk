import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskHost

/// W10 — the host env wiring for agent detection: the default idiom of the two flags
/// (`AISLOPDESK_AGENT_DETECT` default-ON, `AISLOPDESK_AGENT_HOOKS` default-OFF) and the
/// `AISLOPDESK_SOCKET_PATH` / `AISLOPDESK_PANE_ID` PTY-env injection.
final class AgentEnvironmentTests: XCTestCase {
    override func tearDown() {
        EnvConfig.overlay = [:] // the overlay is process-wide; never leak a reaches-consumer override
        super.tearDown()
    }

    // MARK: AISLOPDESK_AGENT_DETECT — DEFAULT-ON (`!= "0"`)

    func testAgentDetectDefaultsOn() {
        XCTAssertTrue(HostEnvironment.agentDetectEnabled(environment: [:]), "unset → enabled (default-ON)")
        XCTAssertTrue(HostEnvironment.agentDetectEnabled(environment: ["AISLOPDESK_AGENT_DETECT": "1"]))
        XCTAssertTrue(
            HostEnvironment.agentDetectEnabled(environment: ["AISLOPDESK_AGENT_DETECT": "anything"]),
            "any value other than exactly \"0\" enables",
        )
    }

    func testAgentDetectOnlyZeroDisables() {
        XCTAssertFalse(
            HostEnvironment.agentDetectEnabled(environment: ["AISLOPDESK_AGENT_DETECT": "0"]),
            "only the exact string \"0\" disables",
        )
    }

    // MARK: AISLOPDESK_AGENT_HOOKS — DEFAULT-OFF (`== "1"`)

    func testAgentHooksDefaultsOff() {
        XCTAssertFalse(HostEnvironment.agentHooksEnabled(environment: [:]), "unset → disabled (default-OFF)")
        XCTAssertFalse(HostEnvironment.agentHooksEnabled(environment: ["AISLOPDESK_AGENT_HOOKS": "0"]))
        XCTAssertFalse(
            HostEnvironment.agentHooksEnabled(environment: ["AISLOPDESK_AGENT_HOOKS": "yes"]),
            "only the exact string \"1\" enables",
        )
    }

    func testAgentHooksOnlyOneEnables() {
        XCTAssertTrue(HostEnvironment.agentHooksEnabled(environment: ["AISLOPDESK_AGENT_HOOKS": "1"]))
    }

    // MARK: W12 — the settings overlay REACHES the agent gates (via the DEFAULT-arg path)

    /// REACHES-CONSUMER (P1): a Settings toggle folded into ``EnvConfig/overlay`` drives the host's
    /// agent-detection gates when called with NO explicit `environment:` (the production call shape in
    /// `aislopdesk-hostd`). The default arg resolves through `HostEnvironment.configEnv` → `EnvConfig`,
    /// so the overlay value lands at the gate. With an EMPTY overlay (and no real env var in the test
    /// runner) the gates keep today's compile-time defaults: detect ON, hooks OFF.
    ///
    /// Guard: only run when the test process does NOT set these as real env vars (a real env var WINS
    /// over the overlay by decision #16, which would mask the overlay path being asserted here).
    func testOverlayReachesAgentGatesViaDefaultArg() throws {
        let realEnv = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            realEnv["AISLOPDESK_AGENT_DETECT"] != nil || realEnv["AISLOPDESK_AGENT_HOOKS"] != nil,
            "a real env var would win over the overlay (decision #16) — not the path under test",
        )
        EnvConfig.overlay = [:]

        // Empty overlay ⇒ today's defaults via the default-arg path.
        XCTAssertTrue(HostEnvironment.agentDetectEnabled(), "empty overlay ⇒ detect default-ON")
        XCTAssertFalse(HostEnvironment.agentHooksEnabled(), "empty overlay ⇒ hooks default-OFF")

        // A settings override in the overlay reaches the gate (no explicit environment: arg).
        EnvConfig.overlay["AISLOPDESK_AGENT_DETECT"] = "0" // OFF
        EnvConfig.overlay["AISLOPDESK_AGENT_HOOKS"] = "1" // ON
        XCTAssertFalse(HostEnvironment.agentDetectEnabled(), "overlay AISLOPDESK_AGENT_DETECT=0 ⇒ detect OFF")
        XCTAssertTrue(HostEnvironment.agentHooksEnabled(), "overlay AISLOPDESK_AGENT_HOOKS=1 ⇒ hooks ON")
    }

    // MARK: socket / pane env injection

    func testCuratedOmitsAgentVarsByDefault() {
        let env = HostEnvironment.curated(parent: [:])
        XCTAssertNil(env["AISLOPDESK_SOCKET_PATH"], "no socket exported unless the listener is bound")
        XCTAssertNil(env["AISLOPDESK_PANE_ID"])
    }

    func testCuratedExportsSocketAndPaneWhenProvided() {
        let env = HostEnvironment.curated(
            parent: [:],
            agentSocketPath: "/tmp/aislopdesk-agent.sock",
            paneID: "conn:7",
        )
        XCTAssertEqual(env["AISLOPDESK_SOCKET_PATH"], "/tmp/aislopdesk-agent.sock")
        XCTAssertEqual(env["AISLOPDESK_PANE_ID"], "conn:7")
    }

    func testPaneIDIsTheCompositeKey() {
        let conn = UUID()
        let id = HostServer.paneID(connectionID: conn, channelID: 4)
        XCTAssertEqual(id, "\(conn.uuidString):4", "the pane id is the (connectionID, channelID) composite")
    }
}
