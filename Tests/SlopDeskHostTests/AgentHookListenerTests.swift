import Darwin
import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The hook path's ROUTING: what one body reads as at the door, what a framed record splits into,
/// and the one drain test that opens a real descriptor.
///
/// The FOLD is not here any more. It was — an `AgentHookHandler` carrying its own
/// `ClaudeStatusMachine` (``rust/slopdesk-agent``'s `machine`) and its own dedupe anchor, driven by
/// thirteen tests in this file and
/// constructed by nothing in `Sources/`. Every behaviour they asserted belongs to the machine, and
/// the live listener's sink reaches it through ``ClaudePaneDetector``, so they now run against the
/// fold that actually executes — including the validate-then-drop cases, which had never been
/// asserted against it at all.
final class AgentHookListenerTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: body → event — not here any more

    //
    // The reading itself is `rust/slopdesk-hookevent`'s, reached through the detector's one hook
    // door: the body crosses as the bytes hostd read off the socket, and parsing and folding happen
    // in that call. So the kind byte a `Notification` earns and the shape a `Stop` reads as are
    // pinned in that crate, beside the parser that decides them, rather than against a second
    // reading here.

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
    /// detector the live sink feeds → the right type-27. (No socket is touched — hang-safety.)
    func testSplitThenFoldProducesStatus() {
        let record = Data("pane=p1\n{\"hook_event_name\":\"UserPromptSubmit\"}".utf8)
        let (paneID, body) = AgentHookRecord.split(record)
        XCTAssertEqual(paneID, "p1")
        let detector = ClaudePaneDetector()
        let emission = detector.hook(bytes: body, at: 0)
        XCTAssertEqual(
            emission.status,
            .claudeStatus(state: 3, kind: 0, label: ""),
            "framed UserPromptSubmit → working",
        )
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
