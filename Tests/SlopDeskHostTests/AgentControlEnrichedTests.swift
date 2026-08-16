import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// The enriched agent-control surface: `list-panes` metadata (cwd / lastExitCode / command /
/// stateMessage), the gates on the block-aware `last-output` and `run --wait` verbs, `wait --state`,
/// and named-key `write`.
///
/// Hang-safe: no real PTY, no real socket. Sessions are built on an unspawned ``PTYProcess``
/// and driven through the `…ForTesting` seams; the pure ``AgentControlHandler/dispatch`` is
/// called directly (the blocking arms run on helper threads bounded by short timeouts).
///
/// The block verbs' ANSWERS are not provable from here any more, and deliberately so: superd holds
/// the ring, so what those verbs return is a round trip to a daemon, not a read of a Swift object.
/// ``SupervisedBlocksTests`` drives them against a real one with a real shell; what stays here is
/// what an unattached pane can still be asked — the refusals, and the pure tail hygiene.
final class AgentControlEnrichedTests: XCTestCase {
    /// The `screen` verb renders through `slopdesk-screend`; skip by name when it is not built.
    override func setUpWithError() throws {
        try ScreendFixture.requireDaemon()
    }

    private let ESC = "\u{1B}"

    private func makeSession(blocksEnabled: Bool = true) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: unattachedPTY(), // unspawned — no read loop, no reaper
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            blocksEnabled: blocksEnabled,
        )
    }

    /// A server with `session` registered in the live map, addressable by its pane UUID.
    private func makeServer(with session: MuxChannelSession) -> HostServer {
        let server = HostServer(port: 0)
        server.registerMuxSessionForTesting(
            session, key: MuxSessionKey(connectionID: UUID(), channelID: 1),
        )
        return server
    }

    private let allowAll = IPCGuards(allowSendKeys: true, allowSensitiveSessions: true)

    private func parseResponse(_ line: String) -> [String: Any]? {
        guard let data = line.trimmingCharacters(in: .newlines).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func result(_ line: String) -> [String: Any]? {
        parseResponse(line)?["result"] as? [String: Any]
    }

    // MARK: ControlKeyMap

    // The VOCABULARY is pinned in `rust/slopdesk-workspace/src/send_keys.rs`, where the table is —
    // a second set of expectations here would be the mirror fixture that let the two tables drift
    // in the first place. What stays is the part this side owns: joining a list, and refusing one.

    func testKeyMapJoinsATokenListInOrder() {
        let resolved = ControlKeyMap.bytes(forTokens: ["C-c", "Enter"])
        XCTAssertNil(resolved.unknown)
        XCTAssertEqual(resolved.bytes, [0x03, 0x0D], "the tokens concatenate in the order given")
    }

    func testKeyMapUnknownTokenIsNil() {
        XCTAssertNil(ControlKeyMap.bytes(for: "Frobnicate"))
        XCTAssertNil(ControlKeyMap.bytes(for: ""))
        let resolved = ControlKeyMap.bytes(forTokens: ["Enter", "Bogus"])
        XCTAssertEqual(resolved.unknown, "Bogus", "first unknown token is named")
        XCTAssertTrue(resolved.bytes.isEmpty, "an unknown token yields NO partial bytes")
    }

    // MARK: write --key (dispatch)

    func testWriteWithKeysOnlySucceeds() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "w1", method: "write",
            params: ["paneId": session.sessionID.uuidString, "keys": ["C-c", "Enter"]],
            server: server, guards: allowAll,
        )
        XCTAssertEqual(parseResponse(resp)?["ok"] as? Bool, true)
    }

    func testWriteWithUnknownKeyIsError() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "w2", method: "write",
            params: ["paneId": session.sessionID.uuidString, "keys": ["Enter", "NoSuchKey"]],
            server: server, guards: allowAll,
        )
        let obj = parseResponse(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("NoSuchKey") == true)
    }

    func testWriteWithNeitherTextNorKeysIsError() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "w3", method: "write",
            params: ["paneId": session.sessionID.uuidString],
            server: server, guards: allowAll,
        )
        XCTAssertEqual(parseResponse(resp)?["ok"] as? Bool, false)
    }

    // MARK: list-panes enrichment

    func testListPanesCarriesExitCodeCwdAndStateMessage() {
        let session = makeSession()
        // Prompt-edge probe answers a deterministic cwd (the OSC-7-less shell path).
        session.cwdProbeOverride = { "/tmp/enriched-cwd" }
        let server = makeServer(with: session)

        // One full cycle. superd's sniffer reports `B` (prompt ready) then `C` then `D;3`; the `D`
        // latches lastExitCode, and the prompt edge triggers the (overridden) cwd probe. The chunk's
        // BYTES are incidental — the marks were consumed in superd, and the events are what crossed.
        session.ingestPTYChunkForTesting(
            Data("$ false\r\n".utf8),
            sniffed: [
                .commandIdle(exitCode: nil, durationMS: 0), // 133;B — prompt ready, no exit yet
                .commandRunning,
                .commandIdle(exitCode: 3, durationMS: 0),
            ],
        )
        // An agent self-report supplies the supervision state + human label.
        session.reportAgentStatusForControl(state: "blocked", message: "Approve rm -rf?")

        let resp = AgentControlHandler.dispatch(id: "l1", method: "list-panes", params: [:], server: server)
        let panes = result(resp)?["panes"] as? [[String: Any]]
        XCTAssertEqual(panes?.count, 1)
        let pane = panes?.first
        XCTAssertEqual(pane?["lastExitCode"] as? Int, 3)
        XCTAssertEqual(pane?["cwd"] as? String, "/tmp/enriched-cwd")
        XCTAssertEqual(pane?["state"] as? String, "blocked")
        XCTAssertEqual(pane?["stateMessage"] as? String, "Approve rm -rf?")
        XCTAssertEqual(pane?["command"] as? String, "", "unspawned PTY probe resolves no foreground name")
        XCTAssertEqual(pane?["rows"] as? Int, 0, "unspawned PTY has no winsize")
        XCTAssertNotNil(pane?["cols"] as? Int)
    }

    func testListPanesOmitsUnknownOptionalFields() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(id: "l2", method: "list-panes", params: [:], server: server)
        let pane = (result(resp)?["panes"] as? [[String: Any]])?.first
        XCTAssertNotNil(pane)
        XCTAssertNil(pane?["lastExitCode"], "no D seen → field omitted, not fabricated")
        XCTAssertNil(pane?["cwd"], "no cwd observed → field omitted")
        XCTAssertNil(pane?["stateMessage"])
    }

    // MARK: last-output

    func testLastOutputErrorsWhenBlocksDisabled() {
        let session = makeSession(blocksEnabled: false)
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "o4", method: "last-output",
            params: ["paneId": session.sessionID.uuidString],
            server: server,
        )
        let obj = parseResponse(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("SLOPDESK_BLOCKS") == true)
    }

    // MARK: run --wait

    func testRunWaitErrorsWhenBlocksDisabled() {
        let session = makeSession(blocksEnabled: false)
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "r3", method: "run",
            params: ["paneId": session.sessionID.uuidString, "text": "ls", "wait": true],
            server: server, guards: allowAll,
        )
        let obj = parseResponse(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("SLOPDESK_BLOCKS") == true)
    }

    func testRunWithoutWaitStillAnswersImmediately() {
        // Regression guard: the wait arm must not change the plain `run` contract.
        let session = makeSession(blocksEnabled: false)
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "r4", method: "run",
            params: ["paneId": session.sessionID.uuidString, "text": "ls"],
            server: server, guards: allowAll,
        )
        XCTAssertEqual(parseResponse(resp)?["ok"] as? Bool, true)
    }

    // MARK: wait --state

    func testWaitStateMatchesCurrentStateImmediately() {
        let session = makeSession()
        let server = makeServer(with: session)
        session.reportAgentStatusForControl(state: "done", message: nil)

        let resp = AgentControlHandler.dispatch(
            id: "s1", method: "wait",
            params: [
                "paneId": session.sessionID.uuidString,
                "state": "done,blocked", "timeoutMs": 1000.0,
            ],
            server: server,
        )
        let res = result(resp)
        XCTAssertEqual(res?["matched"] as? Bool, true)
        XCTAssertEqual(res?["state"] as? String, "done")
    }

    func testWaitStateResolvesOnTransition() {
        let session = makeSession()
        let server = makeServer(with: session)
        let paneId = session.sessionID.uuidString

        final class ResponseBox: @unchecked Sendable { var line: String? }
        let box = ResponseBox()
        let done = expectation(description: "wait --state resolved")
        Thread.detachNewThread {
            box.line = AgentControlHandler.dispatch(
                id: "s2", method: "wait",
                params: ["paneId": paneId, "state": "blocked", "timeoutMs": 5000.0],
                server: server,
            )
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        // Fan the transition through the server-level observer stream (the same fan-out the
        // live session wiring drives).
        server.fanAgentStatusChanged(paneId: paneId, title: "t", status: .needsPermission)
        wait(for: [done], timeout: 5.0)

        guard let line = box.line else {
            XCTFail("no response")
            return
        }
        let res = result(line)
        XCTAssertEqual(res?["matched"] as? Bool, true)
        XCTAssertEqual(res?["state"] as? String, "blocked")
    }

    func testWaitStateTimesOut() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "s3", method: "wait",
            params: ["paneId": session.sessionID.uuidString, "state": "blocked", "timeoutMs": 100.0],
            server: server,
        )
        let res = result(resp)
        XCTAssertEqual(res?["matched"] as? Bool, false)
    }

    func testWaitStateRejectsUnknownState() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "s4", method: "wait",
            params: ["paneId": session.sessionID.uuidString, "state": "sleeping"],
            server: server,
        )
        XCTAssertEqual(parseResponse(resp)?["ok"] as? Bool, false)
    }

    func testWaitWithNeitherUntilNorStateIsError() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "s5", method: "wait",
            params: ["paneId": session.sessionID.uuidString],
            server: server,
        )
        let obj = parseResponse(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("until") == true)
    }

    // MARK: PROMPT_SP tail hygiene

    func testStripPromptEOLTailLeavesPlainPercentAlone() {
        // A command whose REAL output ends in `%` + spaces (the pad-to-clear idiom) has no SGR
        // wrapping — the stripper's false-positive guard must leave it untouched.
        let plain = Array("progress: 100%        \r".utf8)
        XCTAssertEqual(AgentControlHandler.stripPromptEOLTail(plain), plain)
    }

    // MARK: screen (rendered-grid dump)

    func testScreenRendersScrollbackAsGrid() {
        let session = makeSession()
        let server = makeServer(with: session)
        // Ring bytes via the REAL replay append path; the unspawned PTY has no winsize → the
        // verb falls back to 24×80.
        session.appendForTesting(Data("hello\r\nworld\(ESC)[1;1HX".utf8))
        let resp = AgentControlHandler.dispatch(
            id: "s1", method: "screen",
            params: ["paneId": session.sessionID.uuidString],
            server: server, guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: false),
        )
        let res = result(resp)
        XCTAssertEqual(res?["rows"] as? Int, 24)
        XCTAssertEqual(res?["cols"] as? Int, 80)
        let lines = res?["lines"] as? [String]
        XCTAssertEqual(lines?.count, 24, "lines is the full grid")
        XCTAssertEqual(lines?[0], "Xello")
        XCTAssertEqual(lines?[1], "world")
        XCTAssertEqual(res?["text"] as? String, "Xello\nworld", "text drops trailing blank rows")
        XCTAssertEqual(res?["cursorRow"] as? Int, 0)
        XCTAssertEqual(res?["cursorCol"] as? Int, 1)
        XCTAssertEqual(res?["altScreen"] as? Bool, false)
    }

    func testScreenIsReadOnlyVerbUnderClosedGuards() {
        // Dispatched above with both guards OFF and it succeeded — pin the classification too.
        XCTAssertFalse(AgentControlHandler.isMutatingVerb("screen"))
    }

    func testScreenShowsOpenAltScreenTUI() {
        let session = makeSession()
        let server = makeServer(with: session)
        session.appendForTesting(
            Data("shell history\(ESC)[?1049h\(ESC)[2J\(ESC)[2;2H-- INSERT --".utf8),
        )
        let res = result(AgentControlHandler.dispatch(
            id: "s2", method: "screen",
            params: ["paneId": session.sessionID.uuidString, "rows": 5, "cols": 20],
            server: server, guards: allowAll,
        ))
        XCTAssertEqual(res?["altScreen"] as? Bool, true)
        XCTAssertEqual(res?["rows"] as? Int, 5, "explicit rows/cols override the fallback size")
        XCTAssertEqual(res?["text"] as? String, "\n -- INSERT --")
    }

    func testScreenRejectsOutOfRangeSize() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "s3", method: "screen",
            params: ["paneId": session.sessionID.uuidString, "rows": 0],
            server: server, guards: allowAll,
        )
        XCTAssertEqual(parseResponse(resp)?["ok"] as? Bool, false)
    }

    func testScreenUnknownPaneIsError() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "s4", method: "screen",
            params: ["paneId": UUID().uuidString],
            server: server, guards: allowAll,
        )
        XCTAssertEqual(parseResponse(resp)?["ok"] as? Bool, false)
    }
}
