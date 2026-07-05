import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskHost

/// Pins the pure ``ClaudeStatus`` → ctl-state-string mapping (P1 supervision API). No socket,
/// no PTY — the mapping is a pure transform. Reverting the mapping to leak the enum case names
/// (e.g. `needsPermission` instead of `blocked`) would fail these.
final class AgentControlStateTests: XCTestCase {
    func testBlockedMapsFromNeedsPermission() {
        // The supervision vocabulary uses "blocked", NOT the host enum case "needsPermission".
        XCTAssertEqual(AgentControlState.string(from: .needsPermission), "blocked")
    }

    func testWorkingDoneIdleMap() {
        XCTAssertEqual(AgentControlState.string(from: .working), "working")
        XCTAssertEqual(AgentControlState.string(from: .done), "done")
        XCTAssertEqual(AgentControlState.string(from: .idle), "idle")
    }

    func testNoneCollapsesToIdle() {
        // A live pane with no detected claude → "idle" (NOT "none"/"unknown"); pinned so the
        // report-verb closed set stays exactly the four supervision states.
        XCTAssertEqual(AgentControlState.string(from: .none), "idle")
    }

    func testAllStatesIsClosedSet() {
        XCTAssertEqual(AgentControlState.allStates, ["idle", "working", "done", "blocked"])
        for s in AgentControlState.allStates {
            XCTAssertTrue(AgentControlState.isValid(s), "\(s) must validate")
        }
        XCTAssertFalse(AgentControlState.isValid("needsPermission"), "enum case name is NOT a wire state")
        XCTAssertFalse(AgentControlState.isValid("none"), "none is not a supervision state")
        XCTAssertFalse(AgentControlState.isValid(""), "empty is invalid")
    }

    /// Every ``ClaudeStatus`` case maps to a string in the closed set (total mapping).
    func testMappingIsTotalIntoClosedSet() {
        for status in ClaudeStatus.allCases {
            let s = AgentControlState.string(from: status)
            XCTAssertTrue(AgentControlState.isValid(s), "\(status) → \(s) must be in the closed set")
        }
    }

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

    func testUnwrapKeepsUnterminatedTrailingLine() {
        // No trailing newline → the final element is a complete-but-unterminated logical line
        // (host-side indistinguishable from a live prompt / "awaiting input" cue the orchestrator
        // scrapes), so it is KEPT — dropping it would swallow the freshest line (review finding).
        let out = MuxChannelSession.unwrapLogicalLines("alpha\nbeta\ngamma")
        XCTAssertEqual(
            out,
            ["alpha", "beta", "gamma"],
            "the unterminated trailing 'gamma' is kept (it may be the prompt)",
        )
    }

    func testUnwrapDropsOnlyTerminatingNewlineArtifact() {
        // Trailing newline → the split's trailing "" is a separator artifact, dropped (no spurious
        // trailing blank), but the real content lines survive.
        let out = MuxChannelSession.unwrapLogicalLines("alpha\nbeta\n")
        XCTAssertEqual(out, ["alpha", "beta"])
    }

    func testUnwrapKeepsBlankLines() {
        let out = MuxChannelSession.unwrapLogicalLines("a\n\nb\n")
        XCTAssertEqual(out, ["a", "", "b"], "blank lines are preserved")
    }

    func testUnwrapLastNCap() {
        let out = MuxChannelSession.unwrapLogicalLines("a\nb\nc\nd\n", lines: 2)
        XCTAssertEqual(out, ["c", "d"], "only the last N logical lines")
    }

    func testUnwrapEmpty() {
        XCTAssertEqual(MuxChannelSession.unwrapLogicalLines(""), [])
    }

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
