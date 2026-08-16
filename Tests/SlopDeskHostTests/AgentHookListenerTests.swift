import Darwin
import Foundation
import SlopDeskAgentDetect
import SlopDeskInspector
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The PURE ``AgentHookHandler`` core, fed REAL Claude Code hook JSON bytes directly, plus the ONE
/// socket-shim test that binds (``testAWedgedSinkDoesNotBlockTheNextClient``). Asserts
/// the correct type-27 ``WireMessage/claudeStatus`` emission + the embedded machine state, plus
/// validate-then-drop on malformed bytes.
final class AgentHookListenerTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: real hook JSON → type-27

    func testSessionStartEmitsIdle() {
        var h = AgentHookHandler()
        let msg = h.handle(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        XCTAssertEqual(h.status, .idle)
        XCTAssertEqual(msg, .claudeStatus(state: 1, kind: 0, label: ""), "SessionStart → idle (urgency 1), kind none")
    }

    func testUserPromptSubmitEmitsWorking() {
        var h = AgentHookHandler()
        _ = h.handle(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        let msg = h.handle(bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#), at: 1)
        XCTAssertEqual(h.status, .working)
        XCTAssertEqual(msg, .claudeStatus(state: 3, kind: 0, label: ""), "UserPromptSubmit → working (urgency 3)")
    }

    func testNotificationPermissionEmitsBlockedWithKindAndLabel() {
        var h = AgentHookHandler()
        let body = #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#
        let msg = h.handle(bytes: json(body), at: 0)
        XCTAssertEqual(h.status, .needsPermission)
        XCTAssertEqual(
            msg,
            .claudeStatus(state: 4, kind: 1, label: "Claude needs your permission to use Bash"),
            "permission Notification → needsPermission (urgency 4), kind permission (1), label = message",
        )
    }

    /// The idle "waiting for your input" nudge is informational — it lifts presence (idle), never
    /// blocks. The genuine blocking classes keep kind 2 (`agent_needs_input` / `AskUserQuestion`).
    func testNotificationIdleWaitingIsPresenceNotBlocked() {
        var h = AgentHookHandler()
        let body = #"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#
        let msg = h.handle(bytes: json(body), at: 0)
        XCTAssertEqual(h.status, .idle)
        guard case let .claudeStatus(state, kind, _)? = msg else { XCTFail("expected claudeStatus")
            return
        }
        XCTAssertEqual(state, 1, "presence floor, not blocked")
        XCTAssertEqual(kind, 3, "informational class")
    }

    func testNotificationAgentNeedsInputEmitsKind2() {
        var h = AgentHookHandler()
        let body = #"{"hook_event_name":"Notification","notification_type":"agent_needs_input","message":"?"}"#
        let msg = h.handle(bytes: json(body), at: 0)
        XCTAssertEqual(h.status, .needsPermission)
        guard case let .claudeStatus(state, kind, _)? = msg else { XCTFail("expected claudeStatus")
            return
        }
        XCTAssertEqual(state, 4)
        XCTAssertEqual(kind, 2, "a genuine input block maps to kind 2")
    }

    func testStopEmitsDoneWithLabel() {
        var h = AgentHookHandler()
        let body = #"{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"All tests pass."}"#
        let msg = h.handle(bytes: json(body), at: 0)
        XCTAssertEqual(h.status, .done)
        XCTAssertEqual(
            msg,
            .claudeStatus(state: 2, kind: 0, label: "All tests pass."),
            "Stop → done (urgency 2), kind none, label = last_assistant_message",
        )
    }

    func testSessionEndEmitsNone() {
        var h = AgentHookHandler()
        _ = h.handle(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        let msg = h.handle(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 1)
        XCTAssertEqual(h.status, .none)
        XCTAssertEqual(msg, .claudeStatus(state: 0, kind: 0, label: ""), "SessionEnd → none (urgency 0)")
    }

    // MARK: validate-then-drop on malformed / unknown bytes

    /// A record naming a DIFFERENT session is dropped by the machine — and must not be announced
    /// on the way out either. `handle` used to fold-then-emit unconditionally, so a nested
    /// `claude -p`'s `PermissionRequest` shipped a type-27 saying the pane's block had changed
    /// class while the machine had not moved at all.
    func testAForeignSessionsRecordIsNotAnnouncedEither() {
        var h = AgentHookHandler()
        _ = h.handle(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"outer"}"#), at: 0)
        let body = #"{"hook_event_name":"Notification","session_id":"outer","#
            + #""message":"Claude needs your permission to use Bash"}"#
        _ = h.handle(bytes: json(body), at: 1)
        XCTAssertEqual(h.status, .needsPermission)

        let nested = h.handle(
            bytes: json(#"{"hook_event_name":"PermissionRequest","session_id":"inner","tool_name":"Read"}"#),
            at: 2,
        )
        XCTAssertEqual(h.status, .needsPermission, "the machine did not move…")
        XCTAssertNil(nested, "…so nothing goes on the wire saying it did")
    }

    func testMalformedBytesAreDropped() {
        var h = AgentHookHandler()
        let msg = h.handle(bytes: json("not json at all {{{"), at: 0)
        XCTAssertNil(msg, "malformed bytes must be dropped (validate-then-drop), not crash")
        XCTAssertEqual(h.status, .none, "a dropped payload changes nothing")
    }

    func testEmptyBytesAreDropped() {
        var h = AgentHookHandler()
        XCTAssertNil(h.handle(bytes: Data(), at: 0))
        XCTAssertEqual(h.status, .none)
    }

    func testUnknownHookEventIsDropped() {
        var h = AgentHookHandler()
        let msg = h.handle(bytes: json(#"{"hook_event_name":"SomethingNew","session_id":"s1"}"#), at: 0)
        XCTAssertNil(msg, "an unrecognized hook event parses to nil → dropped")
    }

    // MARK: dedupe

    func testIdenticalStatusIsNotReEmitted() {
        var h = AgentHookHandler()
        let m1 = h.handle(bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#), at: 0)
        let m2 = h.handle(bytes: json(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#), at: 1)
        XCTAssertNotNil(m1, "first working transition emits")
        // PreToolUse is also working (same state, same kind, same empty label) → deduped.
        XCTAssertNil(m2, "a second working transition with the same triple is deduped")
        XCTAssertEqual(h.status, .working)
    }

    // MARK: done → idle decay via injected clock (no wall clock)

    func testDoneDecaysToIdleOnTick() {
        var h = AgentHookHandler(doneToIdleTimeout: 5)
        _ = h.handle(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#), at: 0)
        XCTAssertEqual(h.status, .done)
        let early = h.tick(at: 4) // before the timeout
        XCTAssertNil(early, "still done before the timeout — no new status")
        let decayed = h.tick(at: 6) // past the timeout
        XCTAssertEqual(h.status, .idle)
        XCTAssertEqual(decayed, .claudeStatus(state: 1, kind: 0, label: ""), "done → idle decay emits type 27")
    }

    // MARK: payload → event mapping unit (the adapter)

    func testNotificationKindByteMapping() {
        XCTAssertEqual(AgentHookHandler.notificationKindByte(.permission), 1)
        XCTAssertEqual(AgentHookHandler.notificationKindByte(.waitingForInput), 2)
        XCTAssertEqual(AgentHookHandler.notificationKindByte(.other), 3)
    }

    func testStopPayloadMapsToStopEventKindZero() {
        let payload = HookPayload.stop(StopInfo(sessionID: "s", lastAssistantMessage: "done"))
        let (event, kind) = AgentHookHandler.mapToHookEvent(payload)
        XCTAssertEqual(event, .stop(sessionID: "s", label: "done"))
        XCTAssertEqual(kind, 0)
    }

    // MARK: record framing split (pane= header + JSON) — the pure routing piece

    func testRecordSplitParsesPaneHeaderAndJSON() {
        let record = Data("pane=conn-1:3\n{\"hook_event_name\":\"Stop\"}".utf8)
        let (paneID, body) = AgentHookRecord.split(record)
        XCTAssertEqual(paneID, "conn-1:3")
        XCTAssertEqual(body, Data("{\"hook_event_name\":\"Stop\"}".utf8))
    }

    func testRecordSplitEmptyPaneHeaderIsNil() {
        let record = Data("pane=\n{\"hook_event_name\":\"Stop\"}".utf8)
        let (paneID, _) = AgentHookRecord.split(record)
        XCTAssertNil(paneID, "an empty pane id routes nowhere (dropped)")
    }

    func testRecordSplitWithoutHeaderTreatsWholeAsJSON() {
        let record = Data("{\"hook_event_name\":\"Stop\"}".utf8)
        let (paneID, body) = AgentHookRecord.split(record)
        XCTAssertNil(paneID, "no pane header → no pane id")
        XCTAssertEqual(body, record, "the whole record is the JSON")
    }

    /// End-to-end over the pure pieces: split a real framed record, then feed the JSON to the
    /// handler → the right type-27. (The socket shim is not touched — hang-safety.)
    func testSplitThenHandleProducesStatus() {
        let record = Data("pane=p1\n{\"hook_event_name\":\"UserPromptSubmit\"}".utf8)
        let (paneID, body) = AgentHookRecord.split(record)
        XCTAssertEqual(paneID, "p1")
        var h = AgentHookHandler()
        let msg = h.handle(bytes: body, at: 0)
        XCTAssertEqual(msg, .claudeStatus(state: 3, kind: 0, label: ""), "framed UserPromptSubmit → working")
    }

    // MARK: - The drain (the only test that opens a real descriptor)

    /// ⚠️ A SLOW SINK MUST NOT STALL THE DRAIN. Delivery used to run inline on the thread that read
    /// the connection, so while one pane's handler worked, every other pane's connection sat
    /// unread — and the peer is Claude Code's hook binary, which BLOCKS the agent until its record
    /// is taken. Measured before the fix: a hook posted 0.5s behind a wedged one took 19.5s to
    /// return, and Claude Code's own 30s hook ceiling is what eventually unstuck it.
    ///
    /// So the assertion is the CLIENT's: its POST completes promptly even while a sink is wedged.
    /// Delivery itself stays serialized behind that sink on purpose — hook events are a per-pane
    /// state machine and order is meaning — which is why this cannot be asserted as "the second
    /// record reaches the sink".
    ///
    /// The two queues that make this true are `drainQueue` and `deliveryQueue`; merging them is
    /// exactly the regression. No socket is BOUND here — superd owns the listener now, so the test
    /// hands the listener the same thing superd would: an accepted, connected descriptor.
    ///
    /// Hang-proof: every wait is an expectation with a timeout, so a regression FAILS rather than
    /// hangs the suite.
    func testAWedgedSinkDoesNotBlockTheNextClient() throws {
        let wedged = expectation(description: "the first record reached the sink and parked there")
        let release = DispatchSemaphore(value: 0)
        let arrivals = Counter()

        let listener = AgentHookListener()
        listener.register(paneID: "a") { _ in
            if arrivals.bump() == 1 {
                wedged.fulfill()
                release.wait() // hold the sink open — the drain must not be waiting on us
            }
        }
        defer {
            release.signal()
            listener.stop()
        }

        let first = try Self.post(Data("pane=a\n{}\n".utf8), to: listener)
        defer { close(first) }
        wait(for: [wedged], timeout: 5)

        // The hook binary's exact shape: write, then wait for the host to close. THAT wait is what
        // used to cost the agent 19.5s, and it ends only when the drain reaches EOF and closes.
        let peer = try Self.post(Data("pane=b\n{}\n".utf8), to: listener)
        defer { close(peer) }
        let returned = expectation(description: "the next client's POST completed")
        DispatchQueue.global().async {
            var sink = [UInt8](repeating: 0, count: 64)
            while read(peer, &sink, sink.count) > 0 {}
            returned.fulfill()
        }
        wait(for: [returned], timeout: 3)
    }

    /// A lock-guarded arrival counter — the sink runs off the test's thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            n += 1
            return n
        }
    }

    /// Hands `listener` one connected descriptor with `record` already written to it, and returns
    /// the peer end — which the caller owns.
    ///
    /// A `socketpair` rather than a bound socket, because there is nothing here to bind any more:
    /// what superd delivers over `SCM_RIGHTS` is an already-accepted connection, and this is one.
    /// The write side is shut down immediately, exactly as the hook binary does, so the drain sees
    /// EOF rather than waiting out its `SO_RCVTIMEO`.
    private static func post(_ record: Data, to listener: AgentHookListener) throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair() failed: \(errno)")
        }
        let (mine, theirs) = (pair[0], pair[1])
        _ = record.withUnsafeBytes { buf in write(mine, buf.baseAddress, buf.count) }
        shutdown(mine, SHUT_WR) // EOF for the drain loop
        listener.serve(connection: theirs)
        return mine
    }
}
