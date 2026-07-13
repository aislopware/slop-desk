import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// The enriched agent-control surface: `list-panes` metadata (cwd / lastExitCode / command /
/// stateMessage), the OSC-133 block-aware `last-output` verb, `run --wait` (block until the
/// command's block closes, answer exit + output), `wait --state`, and named-key `write`.
///
/// Hang-safe: no real PTY, no real socket. Sessions are built on an unspawned ``PTYProcess``
/// and driven through the `…ForTesting` seams; the pure ``AgentControlHandler/dispatch`` is
/// called directly (the blocking arms run on helper threads bounded by short timeouts).
final class AgentControlEnrichedTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"

    /// One full OSC-133 A→D prompt cycle (same fixture shape as `MuxChannelSessionBlocksTests`).
    private func cycle(command: String, output: String, exit: Int) -> String {
        "\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)\(command)\(ESC)]133;C\(BEL)\(output)\(ESC)]133;D;\(exit)\(BEL)"
    }

    private func makeSession(blocksEnabled: Bool = true) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — no read loop, no reaper
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

    func testKeyMapNamedKeys() {
        XCTAssertEqual(ControlKeyMap.bytes(for: "Enter"), [0x0D])
        XCTAssertEqual(ControlKeyMap.bytes(for: "enter"), [0x0D], "named keys are case-insensitive")
        XCTAssertEqual(ControlKeyMap.bytes(for: "Tab"), [0x09])
        XCTAssertEqual(ControlKeyMap.bytes(for: "Escape"), [0x1B])
        XCTAssertEqual(ControlKeyMap.bytes(for: "Backspace"), [0x7F])
        XCTAssertEqual(ControlKeyMap.bytes(for: "Up"), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(ControlKeyMap.bytes(for: "Delete"), [0x1B, 0x5B, 0x33, 0x7E])
        XCTAssertEqual(ControlKeyMap.bytes(for: "F1"), [0x1B, 0x4F, 0x50])
        XCTAssertEqual(ControlKeyMap.bytes(for: "F5"), [0x1B, 0x5B, 0x31, 0x35, 0x7E])
    }

    func testKeyMapControlChords() {
        XCTAssertEqual(ControlKeyMap.bytes(for: "C-c"), [0x03])
        XCTAssertEqual(ControlKeyMap.bytes(for: "C-C"), [0x03], "control fold is case-insensitive like tmux")
        XCTAssertEqual(ControlKeyMap.bytes(for: "C-d"), [0x04])
        XCTAssertEqual(ControlKeyMap.bytes(for: "C-Space"), [0x00])
        XCTAssertEqual(ControlKeyMap.bytes(for: "C-["), [0x1B])
        XCTAssertEqual(ControlKeyMap.bytes(for: "C-?"), [0x7F])
    }

    func testKeyMapMetaChords() {
        XCTAssertEqual(ControlKeyMap.bytes(for: "M-x"), [0x1B, 0x78])
        XCTAssertEqual(ControlKeyMap.bytes(for: "M-Enter"), [0x1B, 0x0D], "meta resolves named keys too")
        XCTAssertEqual(ControlKeyMap.bytes(for: "A-x"), [0x1B, 0x78], "A- is the Alt alias")
    }

    func testKeyMapUnknownTokenIsNil() {
        XCTAssertNil(ControlKeyMap.bytes(for: "Frobnicate"))
        XCTAssertNil(ControlKeyMap.bytes(for: "C-"))
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

        // One full cycle: the sniffer emits `.commandStatus(.idle(exitCode: 3, …))` at D —
        // latching lastExitCode — and the prompt edge triggers the (overridden) cwd probe.
        session.ingestPTYChunkForTesting(Data(cycle(command: "false", output: "", exit: 3).utf8))
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

    func testLastOutputReturnsNewestBlocksWithExitAndOutput() {
        let session = makeSession()
        let server = makeServer(with: session)
        session.feedBlocksForTesting(Data(cycle(command: "echo one", output: "one\n", exit: 0).utf8))
        session.feedBlocksForTesting(Data(cycle(command: "false", output: "", exit: 1).utf8))

        let resp = AgentControlHandler.dispatch(
            id: "o1", method: "last-output",
            params: ["paneId": session.sessionID.uuidString, "n": 2],
            server: server,
        )
        let blocks = result(resp)?["blocks"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 2)
        XCTAssertEqual(blocks?[0]["command"] as? String, "echo one")
        XCTAssertEqual(blocks?[0]["output"] as? String, "one\n")
        XCTAssertEqual(blocks?[0]["exitCode"] as? Int, 0)
        XCTAssertEqual(blocks?[1]["command"] as? String, "false")
        XCTAssertEqual(blocks?[1]["exitCode"] as? Int, 1)
        XCTAssertEqual(blocks?[1]["complete"] as? Bool, true)
        XCTAssertNil(result(resp)?["running"], "no open block → running omitted")
    }

    func testLastOutputDefaultsToSingleNewestBlock() {
        let session = makeSession()
        let server = makeServer(with: session)
        session.feedBlocksForTesting(Data(cycle(command: "echo one", output: "one\n", exit: 0).utf8))
        session.feedBlocksForTesting(Data(cycle(command: "echo two", output: "two\n", exit: 0).utf8))

        let resp = AgentControlHandler.dispatch(
            id: "o2", method: "last-output",
            params: ["paneId": session.sessionID.uuidString],
            server: server,
        )
        let blocks = result(resp)?["blocks"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertEqual(blocks?[0]["command"] as? String, "echo two", "default n=1 → the NEWEST block")
    }

    func testLastOutputSurfacesRunningBlock() {
        let session = makeSession()
        let server = makeServer(with: session)
        // Open a block (C seen) but never close it — a still-running command.
        let partial = "\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)sleep 99\(ESC)]133;C\(BEL)tick"
        session.feedBlocksForTesting(Data(partial.utf8))

        let resp = AgentControlHandler.dispatch(
            id: "o3", method: "last-output",
            params: ["paneId": session.sessionID.uuidString],
            server: server,
        )
        let running = result(resp)?["running"] as? [String: Any]
        XCTAssertEqual(running?["command"] as? String, "sleep 99")
        XCTAssertEqual(running?["outputLen"] as? Int, 4)
    }

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

    func testLastOutputStripsANSIByDefault() {
        let session = makeSession()
        let server = makeServer(with: session)
        session.feedBlocksForTesting(
            Data(cycle(command: "ls", output: "\(ESC)[32mgreen\(ESC)[0m\n", exit: 0).utf8),
        )
        let resp = AgentControlHandler.dispatch(
            id: "o5", method: "last-output",
            params: ["paneId": session.sessionID.uuidString],
            server: server,
        )
        let blocks = result(resp)?["blocks"] as? [[String: Any]]
        XCTAssertEqual(blocks?[0]["output"] as? String, "green\n")
    }

    // MARK: run --wait

    func testRunWaitResolvesWithExitCodeAndOutput() {
        let session = makeSession()
        let server = makeServer(with: session)
        let paneId = session.sessionID.uuidString

        final class ResponseBox: @unchecked Sendable { var line: String? }
        let box = ResponseBox()
        let done = expectation(description: "run --wait resolved")
        let guards = allowAll
        Thread.detachNewThread {
            box.line = AgentControlHandler.dispatch(
                id: "r1", method: "run",
                params: ["paneId": paneId, "text": "make test", "wait": true, "timeoutMs": 5000.0],
                server: server, guards: guards,
            )
            done.fulfill()
        }
        // Give the dispatcher a beat to register its block observer, then close a cycle.
        Thread.sleep(forTimeInterval: 0.1)
        session.feedBlocksForTesting(Data(cycle(command: "make test", output: "ok 12 tests\n", exit: 0).utf8))
        wait(for: [done], timeout: 5.0)

        guard let line = box.line else {
            XCTFail("no response")
            return
        }
        let res = result(line)
        XCTAssertEqual(res?["matched"] as? Bool, true)
        XCTAssertEqual(res?["exitCode"] as? Int, 0)
        XCTAssertEqual(res?["output"] as? String, "ok 12 tests\n")
        XCTAssertEqual(res?["blockIndex"] as? Int, 0)
        XCTAssertNotNil(res?["durationMs"] as? Int)
    }

    func testRunWaitTimesOutWhenNoBlockCloses() {
        let session = makeSession()
        let server = makeServer(with: session)
        let resp = AgentControlHandler.dispatch(
            id: "r2", method: "run",
            params: [
                "paneId": session.sessionID.uuidString,
                "text": "sleep 999", "wait": true, "timeoutMs": 100.0,
            ],
            server: server, guards: allowAll,
        )
        let res = result(resp)
        XCTAssertEqual(res?["matched"] as? Bool, false)
        XCTAssertNil(res?["exitCode"])
    }

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

    func testLastOutputStripsPromptEOLMarkTail() {
        let session = makeSession()
        let server = makeServer(with: session)
        // The exact live-wire shape captured on hardware: command output, then zsh's PROMPT_SP
        // cluster (two-sided-SGR `%` + width fill + anti-xenl tick) immediately before the `D`.
        let fill = String(repeating: " ", count: 79)
        let promptSP = "\(ESC)[1m\(ESC)[7m%\(ESC)[27m\(ESC)[1m\(ESC)[0m\(fill)\r \r"
        let stream = "\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)echo hi\(ESC)]133;C\(BEL)hi\r\n\(promptSP)\(ESC)]133;D;0\(BEL)"
        session.feedBlocksForTesting(Data(stream.utf8))

        let resp = AgentControlHandler.dispatch(
            id: "p1", method: "last-output",
            params: ["paneId": session.sessionID.uuidString],
            server: server,
        )
        let blocks = result(resp)?["blocks"] as? [[String: Any]]
        XCTAssertEqual(blocks?[0]["output"] as? String, "hi\r\n", "PROMPT_SP mark + fill excised from the tail")
    }

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

    // MARK: CommandBlockTracker control surface

    func testTrackerExpectedNextCommandIndexAdvances() {
        var tracker = CommandBlockTracker()
        XCTAssertEqual(tracker.expectedNextCommandIndex, 0, "fresh tracker → next command is block 0")
        _ = tracker.ingest(Data(cycle(command: "a", output: "x\n", exit: 0).utf8))
        XCTAssertEqual(tracker.expectedNextCommandIndex, 1)
        // An EXECUTING open block will consume the next index itself → the caller's command is +1.
        let partial = "\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)b\(ESC)]133;C\(BEL)out"
        _ = tracker.ingest(Data(partial.utf8))
        XCTAssertEqual(tracker.expectedNextCommandIndex, 2)
    }

    func testTrackerRecentBlocksNewestLastWithMeta() {
        var tracker = CommandBlockTracker()
        _ = tracker.ingest(Data(cycle(command: "a", output: "one\n", exit: 0).utf8))
        _ = tracker.ingest(Data(cycle(command: "b", output: "two\n", exit: 2).utf8))
        let recent = tracker.recentBlocksForControl(limit: 5)
        XCTAssertEqual(recent.map(\.commandText), ["a", "b"])
        XCTAssertEqual(recent.last?.exitCode, 2)
        XCTAssertEqual(recent.last.map { String(bytes: $0.output, encoding: .utf8) }, "two\n")
        XCTAssertEqual(tracker.recentBlocksForControl(limit: 1).map(\.commandText), ["b"])
        XCTAssertEqual(tracker.outputBytes(index: 0).map { String(bytes: $0, encoding: .utf8) }, "one\n")
        XCTAssertNil(tracker.outputBytes(index: 9))
    }
}
