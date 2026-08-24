import Foundation
import XCTest
@testable import SlopDeskHost

/// Pins the agent-control socket's DISPATCH — which verb answers what, and in which order it
/// validates — for a host with no panes. No socket, no PTY.
///
/// The supervision VOCABULARY that `report` validates against is not tested here: the mapping
/// (`needsPermission → "blocked"`, `none → "idle"`), the closed set and the total-mapping claim are
/// `slopdesk-agent`'s `supervision`, and ``AgentControlState`` is a face over its doors. Six cases
/// that asserted them a second time in Swift were deleted with the port; what a Swift test can
/// still see, and does below, is that an unknown state is refused BEFORE any session is touched.
final class AgentControlDispatchTests: XCTestCase {
    /// `list-panes` on an empty host still emits a well-formed `panes` array (no `state` to read,
    /// but the verb must not crash). The state-bearing path is covered by the live-PTY test below.
    func testListPanesEmptyStillOK() {
        let server = HostServer(port: 0)
        let resp = AgentControlHandler.dispatch(id: "1", method: "list-panes", params: [:], server: server)
        let obj = (try? JSONSerialization.jsonObject(
            with: Data(resp.trimmingCharacters(in: .newlines).utf8),
        )) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
    }

    // MARK: PIECE 4 — report verb dispatch (validate-then-drop)

    private func obj(_ resp: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(
            with: Data(resp.trimmingCharacters(in: .newlines).utf8),
        )) as? [String: Any]
    }

    func testReportMissingPaneIdIsError() {
        let server = HostServer(port: 0)
        let resp = AgentControlHandler.dispatch(
            id: "1", method: "report", params: ["state": "working"], server: server,
        )
        XCTAssertEqual(obj(resp)?["ok"] as? Bool, false)
    }

    func testReportMissingStateIsError() {
        let server = HostServer(port: 0)
        let resp = AgentControlHandler.dispatch(
            id: "2", method: "report",
            params: ["paneId": "00000000-0000-0000-0000-000000000000"], server: server,
        )
        XCTAssertEqual(obj(resp)?["ok"] as? Bool, false)
    }

    func testReportInvalidStateIsError() {
        let server = HostServer(port: 0)
        // An unknown state string must be REJECTED before touching any session (validate-then-drop).
        let resp = AgentControlHandler.dispatch(
            id: "3", method: "report",
            params: ["paneId": "00000000-0000-0000-0000-000000000000", "state": "frobnicating"],
            server: server,
        )
        let o = obj(resp)
        XCTAssertEqual(o?["ok"] as? Bool, false)
        XCTAssertTrue((o?["error"] as? String)?.contains("invalid state") == true)
    }

    func testReportValidStateUnknownPaneIsNotFound() {
        let server = HostServer(port: 0)
        // A VALID state but a missing pane → "not found" (state validated FIRST, then lookup).
        let resp = AgentControlHandler.dispatch(
            id: "4", method: "report",
            params: ["paneId": "00000000-0000-0000-0000-000000000000", "state": "blocked"],
            server: server,
        )
        let o = obj(resp)
        XCTAssertEqual(o?["ok"] as? Bool, false)
        XCTAssertTrue((o?["error"] as? String)?.contains("not found") == true)
    }

    // MARK: PIECE 3 — unwrapped logical-line split

    //
    // (The split itself is `slopdesk-sanitize`'s `lines::logical_lines`, tested there — including
    // the two cases this verb turns on: an unterminated last line is KEPT because host-side it is
    // indistinguishable from the prompt an orchestrator scrapes, and empty text is NO lines rather
    // than one empty one.)

    func testReadUnwrappedMissingPaneIsError() {
        let server = HostServer(port: 0)
        let resp = AgentControlHandler.dispatch(
            id: "5", method: "read",
            params: ["source": "unwrapped"], server: server,
        )
        XCTAssertEqual(obj(resp)?["ok"] as? Bool, false, "missing paneId is still an error in unwrapped mode")
    }

    // MARK: PIECE 5 — spawn env sentinel keys exist

    func testCuratedExportsControlSocketWhenProvided() {
        let env = HostEnvironment.curated(controlSocketPath: "/tmp/x.sock")
        XCTAssertEqual(env[HostEnvironment.agentControlSocketEnvKey], "/tmp/x.sock")
    }

    func testSentinelKeyConstants() {
        XCTAssertEqual(HostEnvironment.ctlSentinelEnvKey, "SLOPDESK_CTL")
        XCTAssertEqual(HostEnvironment.ctlBinaryEnvKey, "SLOPDESK_CTL_BIN")
    }
}
