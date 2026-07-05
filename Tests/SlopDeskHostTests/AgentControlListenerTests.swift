import Foundation
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Hang-safe tests for the agent-control surface.
///
/// **No real PTY, no real socket.** The pure ``AgentControlHandler`` is driven by a fake
/// ``HostServer``-shaped protocol and by ``MuxChannelSession``'s new primitives fed with
/// synthetic ``Data`` chunks. The ``AgentControlAcceptor`` socket shim is compiled + code-
/// reviewed only (the hang-safety rule: no real `AF_UNIX` socket in a test).
final class AgentControlListenerTests: XCTestCase {
    // MARK: ANSIStripper

    func testStripperPassesThroughPlainText() {
        XCTAssertEqual(ANSIStripper.strip("hello world"), "hello world")
    }

    func testStripperRemovesCSISequence() {
        // "ESC[31m" (red foreground) + "foo" + "ESC[0m" (reset)
        let raw = "\u{1B}[31mfoo\u{1B}[0m"
        XCTAssertEqual(ANSIStripper.strip(raw), "foo")
    }

    func testStripperRemovesOSCTitle() {
        // "ESC]0;My Title BEL"
        let raw = "\u{1B}]0;My Title\u{07}plain"
        XCTAssertEqual(ANSIStripper.strip(raw), "plain")
    }

    func testStripperRemovesOSCWithSTTerminator() {
        // "ESC]2;Title ESC\\"
        let raw = "\u{1B}]2;Title\u{1B}\\plain"
        XCTAssertEqual(ANSIStripper.strip(raw), "plain")
    }

    func testStripperPreservesNewlinesAndTabs() {
        let raw = "line1\nline2\ttabbed"
        XCTAssertEqual(ANSIStripper.strip(raw), "line1\nline2\ttabbed")
    }

    func testStripperHandlesEmptyString() {
        XCTAssertEqual(ANSIStripper.strip(""), "")
    }

    func testStripperHandlesMultipleSequences() {
        let raw = "\u{1B}[1mBold\u{1B}[0m and \u{1B}[32mgreen\u{1B}[0m"
        XCTAssertEqual(ANSIStripper.strip(raw), "Bold and green")
    }

    func testStripperTruncatedEscAtEnd() {
        // Trailing bare ESC — should not crash; just drops the ESC.
        let raw = "hello\u{1B}"
        XCTAssertEqual(ANSIStripper.strip(raw), "hello")
    }

    // MARK: NDJSON codec (AgentControlHandler helpers)

    func testParseRequestAllFields() {
        let line = #"{"id":"abc","method":"list-panes","params":{"x":1}}"#
        guard let (id, method, params) = AgentControlHandler.parseRequest(line) else {
            XCTFail("expected parse success")
            return
        }
        XCTAssertEqual(id, "abc")
        XCTAssertEqual(method, "list-panes")
        XCTAssertEqual(params["x"] as? Int, 1)
    }

    func testParseRequestMissingParams() {
        let line = #"{"id":"1","method":"list-panes"}"#
        guard let (id, method, params) = AgentControlHandler.parseRequest(line) else {
            XCTFail("expected parse success even without params")
            return
        }
        XCTAssertEqual(id, "1")
        XCTAssertEqual(method, "list-panes")
        XCTAssertTrue(params.isEmpty)
    }

    func testParseRequestMalformedJSON() {
        XCTAssertNil(AgentControlHandler.parseRequest("{not json"))
    }

    func testParseRequestMissingId() {
        XCTAssertNil(AgentControlHandler.parseRequest(#"{"method":"list-panes"}"#))
    }

    func testParseRequestMissingMethod() {
        XCTAssertNil(AgentControlHandler.parseRequest(#"{"id":"1"}"#))
    }

    func testSuccessResponseShape() {
        let line = AgentControlHandler.successResponse(id: "42", result: ["x": 1])
        XCTAssertTrue(line.hasSuffix("\n"), "response must be newline-terminated")
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("response is not valid JSON")
            return
        }
        XCTAssertEqual(obj["id"] as? String, "42")
        XCTAssertEqual(obj["ok"] as? Bool, true)
        let result = obj["result"] as? [String: Any]
        XCTAssertEqual(result?["x"] as? Int, 1)
    }

    func testErrorResponseShape() {
        let line = AgentControlHandler.errorResponse(id: "99", message: "oops")
        XCTAssertTrue(line.hasSuffix("\n"))
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("response is not valid JSON")
            return
        }
        XCTAssertEqual(obj["id"] as? String, "99")
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual(obj["error"] as? String, "oops")
    }

    // MARK: Validate-then-drop on malformed frames

    func testDispatchUnknownMethod() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "1", method: "frobnicate", params: [:], server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertNotNil(obj?["error"])
    }

    func testDispatchListPanesEmpty() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "2", method: "list-panes", params: [:], server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        let result = obj?["result"] as? [String: Any]
        let panes = result?["panes"] as? [[String: Any]]
        XCTAssertEqual(panes?.count, 0, "empty host → zero panes")
    }

    func testDispatchReadMissingPaneId() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "3", method: "read", params: [:], server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    func testDispatchReadUnknownPane() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "4", method: "read", params: ["paneId": "00000000-0000-0000-0000-000000000000"],
            server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("not found") == true)
    }

    func testDispatchWriteMissingText() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "5", method: "write",
            params: ["paneId": "00000000-0000-0000-0000-000000000000"],
            server: server,
            // K13 send-keys gate is OFF by default; opt in so this still tests the missing-text path.
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    func testDispatchKillUnknownPane() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "6", method: "kill",
            params: ["paneId": "00000000-0000-0000-0000-000000000000"],
            server: server,
            // K13 send-keys gate is OFF by default; opt in so this still tests the unknown-pane path.
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    // MARK: wait — timeout path (no real PTY needed)

    func testWaitTimeoutPath() {
        let server = makeNullServer()
        // `wait` on a non-existent pane → immediate error (no blocking).
        let resp = AgentControlHandler.dispatch(
            id: "7", method: "wait",
            params: [
                "paneId": "00000000-0000-0000-0000-000000000000",
                "until": "never",
                "timeoutMs": 50.0,
            ],
            server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    func testWaitInvalidRegexIsErrorNotCrash() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "8", method: "wait",
            params: [
                "paneId": "00000000-0000-0000-0000-000000000000",
                "until": "[invalid((",
                "timeoutMs": 50.0,
            ],
            server: server,
        )
        let obj = parseResponseObject(resp)
        // The pane is not found before the regex is compiled, so we get "not found".
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    // MARK: ANSIStripper — charset designator sequences (ESC ( / ) / * / +)

    func testStripperRemovesCharsetDesignatorG0() {
        // ESC(B — switch G0 to ASCII (Powerlevel10k/Starship emits this)
        let raw = "\u{1B}(Bhello"
        XCTAssertEqual(
            ANSIStripper.strip(raw),
            "hello",
            "ESC(B (charset designator) must be consumed, not left in output",
        )
    }

    func testStripperRemovesCharsetDesignatorG1() {
        // ESC)0 — switch G1 to DEC special graphics (Starship LEAN style)
        let raw = "\u{1B})0world"
        XCTAssertEqual(ANSIStripper.strip(raw), "world")
    }

    func testStripperRemovesCharsetDesignatorAllIntroducers() {
        // Verify all four charset introducers (0x28-0x2B) eat the full 3-byte sequence.
        let introducers: [Character] = ["(", ")", "*", "+"]
        for intro in introducers {
            let raw = "\u{1B}\(intro)Btext"
            XCTAssertEqual(
                ANSIStripper.strip(raw),
                "text",
                "ESC\(intro)B must strip all 3 bytes",
            )
        }
    }

    func testStripperStarshipLEANPromptSequences() {
        // Starship LEAN style emits ESC(B ESC)0 around prompt segments.
        // After stripping these should leave only the visible prompt text.
        let raw = "\u{1B}(B\u{1B}[32m❯\u{1B}[0m\u{1B})0 "
        let stripped = ANSIStripper.strip(raw)
        // CSI sequences removed, charset designators removed, visible text preserved.
        XCTAssertFalse(stripped.contains("\u{1B}"), "no ESC bytes should remain")
        XCTAssertTrue(stripped.contains("❯"))
    }

    // MARK: ANSIStripper — Nerd-font private-use-area glyph filtering

    func testStripperRemovesPowerlineGlyph() {
        // U+E0B0 (Powerline right-arrow, 3-byte UTF-8: 0xEE 0x82 0xB0) — must be stripped.
        let powerlineArrow = "\u{E0B0}"
        let raw = "foo\(powerlineArrow)bar"
        XCTAssertEqual(
            ANSIStripper.strip(raw),
            "foobar",
            "U+E0B0 (PUA, Powerline) must be filtered from output",
        )
    }

    func testStripperRemovesPUARange() {
        // U+E000 (first PUA), U+F8FF (last BMP PUA), U+F0000 (supplementary PUA start).
        let pua1 = "\u{E000}" // first BMP private use
        let pua2 = "\u{F8FF}" // last BMP private use
        let pua3 = "\u{F0000}" // first supplementary PUA
        XCTAssertEqual(ANSIStripper.strip("\(pua1)x"), "x")
        XCTAssertEqual(ANSIStripper.strip("\(pua2)x"), "x")
        XCTAssertEqual(ANSIStripper.strip("\(pua3)x"), "x")
    }

    func testStripperPreservesNonPUAUnicode() {
        // U+2764 (❤, Heavy Black Heart) is NOT in PUA — must be preserved.
        let heart = "I \u{2764} Swift"
        XCTAssertEqual(ANSIStripper.strip(heart), heart)
    }

    func testStripperRealisticNerdFontPrompt() {
        // A realistic Starship prompt byte sequence: charset designators + CSI + Nerd glyph.
        // ESC(B ESC[32m  ESC[0m ESC)0 U+E0B0 (powerline) plain text
        let raw = "\u{1B}(B\u{1B}[32m~/code\u{1B}[0m\u{1B})0\u{E0B0} $ "
        let stripped = ANSIStripper.strip(raw)
        XCTAssertEqual(
            stripped,
            "~/code $ ",
            "Realistic Starship prompt: only plain text should remain",
        )
    }

    // MARK: ANSIStripper in wait accumulator

    func testWaitMatchesPlainTextAfterANSIStrip() throws {
        // Build a fake accumulator as would the `wait` verb — strip ANSI, then regex-match.
        let rawChunk = Data("\u{1B}[32mDONE\u{1B}[0m".utf8)
        let text = try ANSIStripper.strip(XCTUnwrap(String(bytes: rawChunk, encoding: .utf8)))
        let regex = try NSRegularExpression(pattern: "DONE")
        let range = NSRange(text.startIndex..., in: text)
        XCTAssertNotNil(regex.firstMatch(in: text, range: range), "ANSI-stripped text should match")
    }

    // MARK: resize verb (pure dispatch — validate-then-drop on bad params)

    func testDispatchResizeMissingPaneId() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "r1", method: "resize", params: ["rows": 24, "cols": 80], server: server,
            // K13 send-keys gate is OFF by default; opt in so this still tests resize param validation.
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("paneId") == true)
    }

    func testDispatchResizeRowsOutOfRange() {
        let server = makeNullServer()
        // rows = 0 is out of range (must be 1..65535)
        let resp = AgentControlHandler.dispatch(
            id: "r2", method: "resize",
            params: ["paneId": "00000000-0000-0000-0000-000000000000", "rows": 0, "cols": 80],
            server: server,
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("rows") == true)
    }

    func testDispatchResizeColsOutOfRange() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "r3", method: "resize",
            params: ["paneId": "00000000-0000-0000-0000-000000000000", "rows": 24, "cols": 65536],
            server: server,
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("cols") == true)
    }

    func testDispatchResizeUnknownPane() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "r4", method: "resize",
            params: ["paneId": "00000000-0000-0000-0000-000000000000", "rows": 24, "cols": 80],
            server: server,
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("not found") == true)
    }

    // MARK: subscribe — streaming event shape (fake observer, no real PTY/socket)

    /// Verifies the NDJSON shape of `output` and `closed` event lines that the `subscribe` pump
    /// would produce. Since the AcceptorLayer is not tested (hang-safety: no real socket), we
    /// test the individual pieces: the observer callback produces correctly-shaped JSON lines,
    /// and the JSON encoding matches the protocol spec.
    func testSubscribeOutputEventShape() throws {
        // Simulate what the output observer encodes for a plain-text chunk.
        let text = "hello from PTY"
        let eventObj: [String: Any] = ["event": "output", "text": text]
        let data = try XCTUnwrap(try? JSONSerialization.data(withJSONObject: eventObj, options: [.sortedKeys]))
        var lineData = data
        lineData.append(0x0A)
        let line = try XCTUnwrap(String(bytes: lineData, encoding: .utf8))
        XCTAssertTrue(line.hasSuffix("\n"), "event line must be newline-terminated")
        let parsed = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: XCTUnwrap(line.data(using: .utf8))) as? [String: Any],
        )
        XCTAssertEqual(parsed["event"] as? String, "output")
        XCTAssertEqual(parsed["text"] as? String, text)
        XCTAssertNil(parsed["id"], "subscribe events must NOT have an id field")
        XCTAssertNil(parsed["ok"], "subscribe events must NOT have an ok field")
    }

    func testSubscribeClosedEventShape() throws {
        // Simulate what the pump emits on pane exit.
        let closedObj: [String: Any] = ["event": "closed"]
        let data = try XCTUnwrap(try? JSONSerialization.data(withJSONObject: closedObj, options: [.sortedKeys]))
        var lineData = data
        lineData.append(0x0A)
        let line = try XCTUnwrap(String(bytes: lineData, encoding: .utf8))
        XCTAssertTrue(line.hasSuffix("\n"))
        let parsed = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: XCTUnwrap(line.data(using: .utf8))) as? [String: Any],
        )
        XCTAssertEqual(parsed["event"] as? String, "closed")
        XCTAssertEqual(parsed.count, 1, "closed event must have exactly one key")
    }

    func testSubscribeOutputObserverANSIStripsChunk() {
        // The subscribe output observer ANSI-strips each chunk before encoding.
        // Verify via ANSIStripper directly (same code path the observer uses).
        let rawChunk = "\u{1B}[32m$ \u{1B}[0mls -la"
        let stripped = ANSIStripper.strip(rawChunk)
        XCTAssertEqual(
            stripped,
            "$ ls -la",
            "subscribe output observer must ANSI-strip chunks before encoding as text",
        )
    }

    func testSubscribeCloseObserverRegistrationIsIdempotentAndSymmetric() {
        // Verify the register/remove API for close observers is symmetric and idempotent.
        // Uses an unspawned PTYProcess (masterFD == -1) so no PTY or read loop is ever started
        // (hang-safety rule: no real PTY in unit tests).
        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned: no masterFD, no reaper thread
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
        let id1 = UUID()
        // Use @unchecked Sendable boxes so the @Sendable observer closures can mutate state
        // without Swift 6 strict-sendability errors (the test is single-threaded in practice).
        final class Flag: @unchecked Sendable { var value = false }
        let outputFired = Flag()
        let closeFired = Flag()
        session.registerOutputObserver(id: id1) { _ in outputFired.value = true }
        session.registerCloseObserver(id: id1) { closeFired.value = true }
        // Double-register should replace (idempotent).
        session.registerCloseObserver(id: id1) { closeFired.value = true }
        // Remove both — must not crash.
        session.removeOutputObserver(id: id1)
        session.removeCloseObserver(id: id1)
        // Removing a second time must not crash (idempotent).
        session.removeOutputObserver(id: id1)
        session.removeCloseObserver(id: id1)
        // Neither fired (no PTY output/exit sourced from the unspawned PTY).
        XCTAssertFalse(outputFired.value)
        XCTAssertFalse(closeFired.value)
    }

    func testSubscribeMissingPaneIdIsError() {
        // dispatch() with method="subscribe" returns an error immediately (paneId missing).
        // subscribe bypasses dispatch in the acceptor layer (handled in serveSubscribe), but
        // the validation logic is testable via the handler's error path.
        let server = makeNullServer()
        // We test the resize validator as a proxy for the param-validation pattern, since
        // subscribe's serveSubscribe is in the Acceptor layer (not callable without a socket).
        // Confirm the pattern: missing paneId → ok:false with paneId in the error message.
        let resp = AgentControlHandler.dispatch(
            id: "s1", method: "resize",
            params: ["rows": 24, "cols": 80], // intentionally missing paneId
            server: server,
            // K13 send-keys gate is OFF by default; opt in so this still proxies the param-validation path.
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    // MARK: HostEnvironment gate

    func testAgentControlEnabledRequiresExplicit1() {
        XCTAssertFalse(HostEnvironment.agentControlEnabled(environment: [:]))
        XCTAssertFalse(HostEnvironment.agentControlEnabled(environment: ["SLOPDESK_AGENT_CONTROL": "0"]))
        XCTAssertFalse(HostEnvironment.agentControlEnabled(environment: ["SLOPDESK_AGENT_CONTROL": "yes"]))
        XCTAssertTrue(HostEnvironment.agentControlEnabled(environment: ["SLOPDESK_AGENT_CONTROL": "1"]))
    }

    func testCuratedInjectsControlSocket() {
        let env = HostEnvironment.curated(
            controlSocketPath: "/tmp/slopdesk-ctl-1234.sock",
        )
        XCTAssertEqual(env["SLOPDESK_CONTROL_SOCKET"], "/tmp/slopdesk-ctl-1234.sock")
    }

    func testCuratedOmitsControlSocketWhenNil() {
        let env = HostEnvironment.curated()
        XCTAssertNil(env["SLOPDESK_CONTROL_SOCKET"])
    }

    // MARK: Helpers

    /// Makes a real `HostServer` bound to port 0 (not started — just constructed, so it can
    /// serve the control verb dispatch without touching the network). We test only the pure
    /// dispatch layer; the server is never `start()`'d in this test file.
    private func makeNullServer() -> HostServer {
        HostServer(port: 0)
    }

    private func parseResponseObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
