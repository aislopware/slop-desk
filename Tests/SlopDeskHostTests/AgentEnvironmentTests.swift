import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskHost

/// W10 — the host env wiring for agent detection: the `SLOPDESK_SOCKET_PATH` / `SLOPDESK_PANE_ID`
/// PTY-env injection.
///
/// There are no detection GATES left to assert. `SLOPDESK_AGENT_DETECT`, `_AGENT_SCREEN` and
/// `_AGENT_HOOKS` are all gone — the watch runs, the screen engine runs, the listener binds — so
/// the truth tables that used to live here have nothing to resolve.
final class AgentEnvironmentTests: XCTestCase {
    override func tearDown() {
        EnvConfig.overlay = [:] // the overlay is process-wide; never leak a reaches-consumer override
        super.tearDown()
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

    /// The daemon-side cursor-shape opt-out (`SLOPDESK_SHELL_CURSOR=0`) must be forwarded into the
    /// curated child env — the shim's `.zshrc` reads `${SLOPDESK_SHELL_CURSOR:-1}` in the CHILD
    /// (same contract as `SLOPDESK_OSC133`), so the allowlist must carry it or the opt-out is dead code.
    func testCuratedForwardsShellCursorOptOut() {
        let env = HostEnvironment.curated(parent: ["SLOPDESK_SHELL_CURSOR": "0", "HOME": "/Users/x"])
        XCTAssertEqual(env["SLOPDESK_SHELL_CURSOR"], "0", "the daemon-side cursor opt-out must reach the child shell")
    }

    /// When unset, curated must not synthesize it — the shim's default-ON branch must be preserved.
    func testCuratedOmitsShellCursorWhenUnset() {
        let env = HostEnvironment.curated(parent: ["HOME": "/Users/x"])
        XCTAssertNil(env["SLOPDESK_SHELL_CURSOR"], "an unset cursor flag must not be materialized")
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
