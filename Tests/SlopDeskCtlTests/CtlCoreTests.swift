import Foundation
import SlopDeskCtlCore
import XCTest

/// Hang-safe tests for the slopdesk-ctl CLI's pure core.
///
/// No real socket, no real PTY. The ``SlopDeskCtlCore`` library (arg-parsing +
/// NDJSON helpers + verb param builders) is driven directly. The ``slopdesk-ctl``
/// executable's socket I/O (``sendRequest``) is NOT exercised here — it lives in
/// ``main.swift`` and is compiled + code-reviewed only (hang-safety rule: no real
/// AF_UNIX socket in a unit test).
final class CtlCoreTests: XCTestCase {
    // MARK: - parseGlobal

    func testParseGlobalSubcommandOnly() {
        let result = parseGlobal(["slopdesk-ctl", "list-panes"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.subcommand, "list-panes")
        XCTAssertEqual(g.socketPath, "")
        XCTAssertTrue(g.rest.isEmpty)
    }

    func testParseGlobalSocketFlag() {
        let result = parseGlobal(["slopdesk-ctl", "--socket", "/tmp/test.sock", "read", "some-uuid"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.socketPath, "/tmp/test.sock")
        XCTAssertEqual(g.subcommand, "read")
        XCTAssertEqual(g.rest, ["some-uuid"])
    }

    func testParseGlobalHelpShort() {
        let result = parseGlobal(["slopdesk-ctl", "-h"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.subcommand, "help")
    }

    func testParseGlobalHelpLong() {
        let result = parseGlobal(["slopdesk-ctl", "--help"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.subcommand, "help")
    }

    func testParseGlobalUnknownFlagBeforeSubcommand() {
        let result = parseGlobal(["slopdesk-ctl", "--bogus"])
        guard case let .failure(err) = result else {
            XCTFail("expected failure on unknown flag")
            return
        }
        XCTAssertEqual(err, .unknownFlag("--bogus"))
    }

    func testParseGlobalSocketMissingValue() {
        let result = parseGlobal(["slopdesk-ctl", "--socket"])
        guard case let .failure(err) = result else {
            XCTFail("expected failure on missing value")
            return
        }
        XCTAssertEqual(err, .missingValue("--socket"))
    }

    func testParseGlobalRestArgs() {
        // `run foo --cmd ls` → subcommand="run", rest=["foo", "--cmd", "ls"]
        let result = parseGlobal(["slopdesk-ctl", "run", "foo-uuid", "--cmd", "ls"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.subcommand, "run")
        XCTAssertEqual(g.rest, ["foo-uuid", "--cmd", "ls"])
    }

    func testParseGlobalEmptyArgs() {
        let result = parseGlobal(["slopdesk-ctl"])
        guard case let .success(g) = result else {
            XCTFail("expected success even with no subcommand")
            return
        }
        XCTAssertEqual(g.subcommand, "")
        XCTAssertTrue(g.rest.isEmpty)
    }

    // MARK: - encodeRequestLine

    func testEncodeRequestLineShape() throws {
        let line = try XCTUnwrap(encodeRequestLine(id: "42", method: "list-panes", params: [:]))
        // Must be valid JSON.
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, "42")
        XCTAssertEqual(obj["method"] as? String, "list-panes")
        XCTAssertNotNil(obj["params"])
        // No trailing LF — the caller appends it.
        XCTAssertFalse(line.hasSuffix("\n"), "encodeRequestLine must NOT append a newline")
    }

    func testEncodeRequestLineWithParams() throws {
        let line = try XCTUnwrap(
            encodeRequestLine(id: "1", method: "read", params: ["paneId": "abc", "ansiStrip": true]),
        )
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["paneId"] as? String, "abc")
        XCTAssertEqual(params["ansiStrip"] as? Bool, true)
    }

    // MARK: - decodeResponseLine

    func testDecodeResponseSuccess() {
        let line = #"{"id":"1","ok":true,"result":{"text":"hello"}}"#
        let obj = decodeResponseLine(line)
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        let result = obj?["result"] as? [String: Any]
        XCTAssertEqual(result?["text"] as? String, "hello")
    }

    func testDecodeResponseError() {
        let line = #"{"id":"1","ok":false,"error":"pane not found"}"#
        let obj = decodeResponseLine(line)
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["error"] as? String, "pane not found")
    }

    func testDecodeResponseMalformed() {
        XCTAssertNil(decodeResponseLine("{not valid json"))
    }

    func testDecodeResponseEmpty() {
        XCTAssertNil(decodeResponseLine(""))
    }

    // MARK: - Verb param builders

    func testRunParamsEncoding() throws {
        // The key behaviour being tested: `run foo --cmd ls` must encode as
        // {"method":"run","params":{"paneId":"foo","text":"ls"}} so that
        // the server sends "ls\r" to the PTY master fd (the Enter is appended
        // server-side by the `run` verb handler).
        let params = runParams(paneId: "foo-uuid", cmd: "ls")
        XCTAssertEqual(params["paneId"] as? String, "foo-uuid")
        XCTAssertEqual(params["text"] as? String, "ls")
        // Validate that the full request line encodes correctly.
        let line = try XCTUnwrap(encodeRequestLine(id: "1", method: "run", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedParams = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(obj["method"] as? String, "run")
        XCTAssertEqual(decodedParams["paneId"] as? String, "foo-uuid")
        XCTAssertEqual(decodedParams["text"] as? String, "ls")
    }

    func testWaitParamsDefaults() {
        let params = waitParams(paneId: "p1", until: "\\$")
        XCTAssertEqual(params["paneId"] as? String, "p1")
        XCTAssertEqual(params["until"] as? String, "\\$")
        XCTAssertEqual(params["timeoutMs"] as? Double, 30000)
    }

    func testWaitParamsCustomTimeout() {
        let params = waitParams(paneId: "p1", until: "DONE", timeoutMs: 5000)
        XCTAssertEqual(params["timeoutMs"] as? Double, 5000)
    }

    func testSpawnParamsNoCmd() {
        let params = spawnParams(cmd: nil, cwd: nil, env: [:], rows: 24, cols: 80)
        XCTAssertNil(params["cmd"], "no --cmd → no cmd param (server spawns login shell)")
        XCTAssertEqual(params["rows"] as? Int, 24)
        XCTAssertEqual(params["cols"] as? Int, 80)
    }

    func testSpawnParamsWithCmd() {
        let params = spawnParams(
            cmd: "ls -la",
            cwd: "/tmp",
            env: ["FOO": "bar"],
            rows: 30,
            cols: 120,
            shellPath: "/bin/zsh",
        )
        let cmd = params["cmd"] as? [String]
        XCTAssertEqual(cmd, ["/bin/zsh", "-c", "ls -la"])
        XCTAssertEqual(params["cwd"] as? String, "/tmp")
        let env = params["env"] as? [String: String]
        XCTAssertEqual(env?["FOO"], "bar")
        XCTAssertEqual(params["rows"] as? Int, 30)
        XCTAssertEqual(params["cols"] as? Int, 120)
    }

    func testReadParamsDefaultAnsiStrip() {
        let params = readParams(paneId: "x")
        XCTAssertEqual(params["ansiStrip"] as? Bool, true)
    }

    func testReadParamsKeepAnsi() {
        let params = readParams(paneId: "x", ansiStrip: false)
        XCTAssertEqual(params["ansiStrip"] as? Bool, false)
    }

    func testWriteParams() {
        let params = writeParams(paneId: "y", text: "hello\u{03}")
        XCTAssertEqual(params["paneId"] as? String, "y")
        XCTAssertEqual(params["text"] as? String, "hello\u{03}")
    }

    // MARK: PIECE 3 — read --unwrapped params

    func testReadParamsPlainHasNoSource() {
        let params = readParams(paneId: "x")
        XCTAssertNil(params["source"], "plain read carries no source param")
        XCTAssertNil(params["lines"])
    }

    func testReadParamsUnwrappedSetsSource() {
        let params = readParams(paneId: "x", unwrapped: true)
        XCTAssertEqual(params["source"] as? String, "unwrapped")
        XCTAssertNil(params["lines"], "no lines cap unless requested")
    }

    func testReadParamsUnwrappedWithLines() {
        let params = readParams(paneId: "x", unwrapped: true, lines: 40)
        XCTAssertEqual(params["source"] as? String, "unwrapped")
        XCTAssertEqual(params["lines"] as? Int, 40)
    }

    func testReadParamsLinesIgnoredWithoutUnwrapped() {
        // A lines cap without --unwrapped is NOT sent as a param (the host doesn't honour it for
        // the plain path; the CLI trims client-side).
        let params = readParams(paneId: "x", unwrapped: false, lines: 40)
        XCTAssertNil(params["lines"])
        XCTAssertNil(params["source"])
    }

    // MARK: PIECE 4 — report params

    func testReportParamsMinimal() {
        let params = reportParams(paneId: "p", state: "working", message: nil)
        XCTAssertEqual(params["paneId"] as? String, "p")
        XCTAssertEqual(params["state"] as? String, "working")
        XCTAssertNil(params["message"], "no message key when nil")
    }

    func testReportParamsWithMessage() {
        let params = reportParams(paneId: "p", state: "blocked", message: "approve the rm?")
        XCTAssertEqual(params["state"] as? String, "blocked")
        XCTAssertEqual(params["message"] as? String, "approve the rm?")
    }

    // MARK: PIECE 2 — top-level subscribe (events) params

    func testSubscribeAllParamsHasNoPaneId() {
        // The top-level events stream is signalled by the ABSENCE of paneId.
        let params = subscribeAllParams()
        XCTAssertNil(params["paneId"], "the events stream carries no paneId (absence = all-mode)")
        XCTAssertTrue(params.isEmpty)
    }

    func testKillParams() {
        let params = killParams(paneId: "z")
        XCTAssertEqual(params["paneId"] as? String, "z")
    }

    func testSubscribeParamsDefaultAnsiStrip() {
        // Default: ansiStrip is true (server strips ANSI — clean agent output).
        let params = subscribeParams(paneId: "sub-uuid")
        XCTAssertEqual(params["paneId"] as? String, "sub-uuid")
        XCTAssertEqual(params["ansiStrip"] as? Bool, true, "subscribeParams default must be ansiStrip:true")
        XCTAssertEqual(params.count, 2, "subscribeParams must contain paneId and ansiStrip")
    }

    func testSubscribeParamsKeepAnsi() {
        // --ansi flag: ansiStrip is false (raw PTY bytes passed through in event text).
        let params = subscribeParams(paneId: "sub-uuid", ansiStrip: false)
        XCTAssertEqual(params["paneId"] as? String, "sub-uuid")
        XCTAssertEqual(params["ansiStrip"] as? Bool, false, "subscribeParams with ansiStrip:false must propagate flag")
    }

    func testResizeParams() {
        let params = resizeParams(paneId: "p", rows: 40, cols: 132)
        XCTAssertEqual(params["paneId"] as? String, "p")
        XCTAssertEqual(params["rows"] as? Int, 40)
        XCTAssertEqual(params["cols"] as? Int, 132)
        XCTAssertEqual(params.count, 3, "resizeParams must contain paneId, rows, cols")
    }

    func testResizeParamsEncoding() throws {
        let params = resizeParams(paneId: "my-pane", rows: 24, cols: 80)
        let line = try XCTUnwrap(encodeRequestLine(id: "rz1", method: "resize", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["method"] as? String, "resize")
        let dp = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(dp["paneId"] as? String, "my-pane")
        XCTAssertEqual(dp["rows"] as? Int, 24)
        XCTAssertEqual(dp["cols"] as? Int, 80)
    }

    func testSubscribeParamsEncoding() throws {
        // Default (ansiStrip: true) encodes both paneId and ansiStrip.
        let params = subscribeParams(paneId: "pane-abc")
        let line = try XCTUnwrap(encodeRequestLine(id: "sub1", method: "subscribe", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["method"] as? String, "subscribe")
        let dp = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(dp["paneId"] as? String, "pane-abc")
        XCTAssertEqual(dp["ansiStrip"] as? Bool, true, "default subscribe must encode ansiStrip:true")
    }

    func testSubscribeParamsKeepAnsiEncoding() throws {
        // --ansi flag (ansiStrip: false): server receives ansiStrip:false and passes raw PTY text.
        let params = subscribeParams(paneId: "pane-xyz", ansiStrip: false)
        let line = try XCTUnwrap(encodeRequestLine(id: "sub2", method: "subscribe", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["method"] as? String, "subscribe")
        let dp = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(dp["paneId"] as? String, "pane-xyz")
        XCTAssertEqual(dp["ansiStrip"] as? Bool, false, "--ansi flag must encode ansiStrip:false")
    }

    func testReadParamsFullRingEncoding() throws {
        // `read --full` clears any line limit: just paneId + ansiStrip (no limit field).
        // This mirrors cmdRead: fullRing=true sets limitLines=nil → same readParams call.
        let params = readParams(paneId: "ring-pane", ansiStrip: true)
        let line = try XCTUnwrap(encodeRequestLine(id: "rf1", method: "read", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["method"] as? String, "read")
        let dp = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(dp["paneId"] as? String, "ring-pane")
        XCTAssertEqual(dp["ansiStrip"] as? Bool, true)
        // No "lines" field — full ring is expressed by the absence of a limit.
        XCTAssertNil(dp["lines"], "--full must not encode a lines field (server returns full scrollback)")
    }

    // MARK: - Round-trip: encode then decode

    func testRoundTripRunRequest() throws {
        // Simulate what the CLI does for `slopdesk-ctl run foo --cmd ls`:
        //   parseGlobal → subcommand="run", rest=["foo", "--cmd", "ls"]
        //   runParams(paneId:"foo", cmd:"ls")
        //   encodeRequestLine → JSON string
        //   (CLI sends over socket; server sends back response)
        //   decodeResponseLine → obj
        let args = ["slopdesk-ctl", "run", "foo", "--cmd", "ls"]
        guard case let .success(global) = parseGlobal(args) else {
            XCTFail("parse failed")
            return
        }
        XCTAssertEqual(global.subcommand, "run")
        // Simulate the CLI's subcommand dispatch:
        // guard !rest.isEmpty → paneId = rest[0]
        // --cmd → cmd = rest[2] (rest = ["foo", "--cmd", "ls"])
        XCTAssertEqual(global.rest, ["foo", "--cmd", "ls"])
        let paneId = global.rest[0]
        XCTAssertEqual(paneId, "foo")
        // In the CLI: parse --cmd from rest[1..].
        var cmd: String?
        var idx = 1
        while idx < global.rest.count {
            if global.rest[idx] == "--cmd", idx + 1 < global.rest.count {
                idx += 1
                cmd = global.rest[idx]
            }
            idx += 1
        }
        XCTAssertEqual(cmd, "ls")
        // Build the params and encode the request.
        let params = try runParams(paneId: paneId, cmd: XCTUnwrap(cmd))
        let line = try XCTUnwrap(encodeRequestLine(id: "req-1", method: "run", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedParams = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, "req-1")
        XCTAssertEqual(obj["method"] as? String, "run")
        XCTAssertEqual(decodedParams["paneId"] as? String, "foo")
        XCTAssertEqual(
            decodedParams["text"] as? String,
            "ls",
            "run verb sends the cmd string as 'text'; server appends \\r",
        )
    }

    func testRoundTripWaitRequest() throws {
        // `slopdesk-ctl wait abc --until "\\$" --timeout-ms 5000`
        let args = ["slopdesk-ctl", "wait", "abc", "--until", "\\$", "--timeout-ms", "5000"]
        guard case let .success(global) = parseGlobal(args) else {
            XCTFail("parse failed")
            return
        }
        XCTAssertEqual(global.subcommand, "wait")
        XCTAssertEqual(global.rest, ["abc", "--until", "\\$", "--timeout-ms", "5000"])
        // Parse rest as the CLI would.
        let paneId = global.rest[0]
        var until: String?
        var timeoutMs: Double = 30000
        var idx = 1
        while idx < global.rest.count {
            switch global.rest[idx] {
            case "--until" where idx + 1 < global.rest.count:
                idx += 1
                until = global.rest[idx]
            case "--timeout-ms" where idx + 1 < global.rest.count:
                idx += 1
                timeoutMs = Double(global.rest[idx]) ?? 30000
            default: break
            }
            idx += 1
        }
        XCTAssertEqual(until, "\\$")
        XCTAssertEqual(timeoutMs, 5000)
        let params = try waitParams(paneId: paneId, until: XCTUnwrap(until), timeoutMs: timeoutMs)
        let line = try XCTUnwrap(encodeRequestLine(id: "w1", method: "wait", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dp = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(dp["paneId"] as? String, "abc")
        XCTAssertEqual(dp["until"] as? String, "\\$")
        XCTAssertEqual(dp["timeoutMs"] as? Double, 5000)
    }

    // MARK: - Enriched verb builders (last-output / run --wait / write --key / wait --state)

    func testLastOutputParamsDefaults() {
        let params = lastOutputParams(paneId: "p1")
        XCTAssertEqual(params["paneId"] as? String, "p1")
        XCTAssertEqual(params["n"] as? Int, 1)
        XCTAssertEqual(params["ansiStrip"] as? Bool, true)
    }

    func testLastOutputParamsExplicit() {
        let params = lastOutputParams(paneId: "p1", n: 5, ansiStrip: false)
        XCTAssertEqual(params["n"] as? Int, 5)
        XCTAssertEqual(params["ansiStrip"] as? Bool, false)
    }

    func testRunParamsWithoutWaitOmitsWaitFields() {
        let params = runParams(paneId: "p1", cmd: "ls")
        XCTAssertEqual(params["text"] as? String, "ls")
        XCTAssertNil(params["wait"], "plain run must stay byte-identical for older hosts")
        XCTAssertNil(params["timeoutMs"])
    }

    func testRunParamsWithWaitCarriesTimeoutAndStrip() {
        let params = runParams(paneId: "p1", cmd: "make", wait: true, timeoutMs: 90000, ansiStrip: false)
        XCTAssertEqual(params["wait"] as? Bool, true)
        XCTAssertEqual(params["timeoutMs"] as? Double, 90000)
        XCTAssertEqual(params["ansiStrip"] as? Bool, false)
    }

    func testWriteParamsTextOnlyBackCompatShape() {
        let params = writeParams(paneId: "p1", text: "hello")
        XCTAssertEqual(params["text"] as? String, "hello")
        XCTAssertNil(params["keys"], "no keys -> field omitted")
    }

    func testWriteParamsKeysOnly() {
        let params = writeParams(paneId: "p1", keys: ["C-c", "Enter"])
        XCTAssertNil(params["text"])
        XCTAssertEqual(params["keys"] as? [String], ["C-c", "Enter"])
    }

    func testWaitStateParamsShape() {
        let params = waitStateParams(paneId: "p1", states: "done,blocked", timeoutMs: 2000)
        XCTAssertEqual(params["state"] as? String, "done,blocked")
        XCTAssertEqual(params["timeoutMs"] as? Double, 2000)
        XCTAssertNil(params["until"], "state arm never carries a regex")
    }

    func testScreenParamsDefaultsToLiveSize() {
        let params = screenParams(paneId: "p1")
        XCTAssertEqual(params["paneId"] as? String, "p1")
        XCTAssertNil(params["rows"], "absent size fields = host uses the live PTY winsize")
        XCTAssertNil(params["cols"])
    }

    func testScreenParamsExplicitSize() {
        let params = screenParams(paneId: "p1", rows: 50, cols: 132)
        XCTAssertEqual(params["rows"] as? Int, 50)
        XCTAssertEqual(params["cols"] as? Int, 132)
    }
}
