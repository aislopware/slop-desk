import XCTest
import Foundation
import AislopdeskProtocol
import AislopdeskTransport
@testable import AislopdeskClient

/// R15 #1 regression: ``ReconnectManager`` must never run a reconnect campaign against a CLOSED client.
///
/// The two deliberate-shutdown paths are asymmetric: ``AislopdeskClient/pause()`` yields its own
/// `.disconnected` and sets `paused`, but ``AislopdeskClient/close()`` sets `closed` and finishes the
/// event stream WITHOUT yielding `.disconnected`. So a REAL transport drop whose `.disconnected`
/// landed just before `close()` sits buffered in a subscriber ahead of the finish — and a supervisor
/// gating only on `isPaused` would pop that stale drop after close and burn the full
/// `maxReconnectAttempts` of `connect`-after-close throws, finally firing a spurious `onGaveUp`.
/// The fix gates the campaign on `isClosed` as well.
final class AislopdeskClientReconnectClosedTests: XCTestCase {

    /// `reconnectLoop()` bails IMMEDIATELY when the client is already closed: no connect attempt
    /// (each would throw `invalidState("connect after close")`), no give-up.
    func testReconnectLoopBailsImmediatelyOnClosedClient() async {
        let client = AislopdeskClient(makeTransport: { FakeTransport() })
        try? await client.connect(host: "h", port: 1)
        await client.close()

        let logs = LineCollector()
        let gaveUp = FlagBox()
        // A tiny backoff so even the UNFIXED (looping) path finishes fast — the assertions, not a
        // wall-clock timeout, are what distinguish fixed from broken.
        await ReconnectManager.reconnectLoop(
            client: client, host: "h", port: 1,
            backoff: .init(initial: .milliseconds(1), maximum: .milliseconds(2), multiplier: 2.0),
            onLog: { logs.append($0) },
            onProgress: { _, _ in },
            onGaveUp: { gaveUp.set() }
        )

        XCTAssertFalse(gaveUp.value, "a closed client must not run a doomed campaign to give-up")
        XCTAssertFalse(
            logs.lines.contains { $0.contains("failed") },
            "no connect attempt should be made against a closed client"
        )
        XCTAssertFalse(
            logs.lines.contains { $0.contains("gave up") },
            "no give-up line for a deliberately-closed client"
        )
    }

    /// Positive control: the guard is NOT over-broad — an open (unpaused, unclosed) client still
    /// reconnects on the first attempt. `FakeTransport.connect` succeeds, so the loop resumes at once.
    func testReconnectLoopStillReconnectsWhenClientOpen() async {
        let client = AislopdeskClient(makeTransport: { FakeTransport() })
        let logs = LineCollector()
        await ReconnectManager.reconnectLoop(
            client: client, host: "h", port: 1,
            backoff: .init(initial: .milliseconds(1), maximum: .milliseconds(2), multiplier: 2.0),
            onLog: { logs.append($0) },
            onProgress: { _, _ in },
            onGaveUp: { }
        )
        XCTAssertTrue(
            logs.lines.contains { $0.contains("resumed") },
            "an open client reconnects on the first attempt (the isClosed/isPaused guard must not block it)"
        )
        await client.close()
    }

    /// `isClosed` is the property the guard reads — it must flip true exactly after `close()`.
    func testIsClosedReflectsClose() async {
        let client = AislopdeskClient(makeTransport: { FakeTransport() })
        let before = await client.isClosed
        XCTAssertFalse(before, "a fresh client is not closed")
        await client.close()
        let after = await client.isClosed
        XCTAssertTrue(after, "isClosed is true after close()")
    }

    // MARK: - Helpers

    /// Minimal `ClientTransporting` stub mirroring `MuxClientTransport`'s session-identity rules so
    /// `AislopdeskClient.connect` exercises its real path. Inbound is an inert stream.
    private actor FakeTransport: ClientTransporting {
        private var _sessionID: UUID?
        private var _resumeFromSeq: Int64 = 0
        private var _returningClient = false
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { _resumeFromSeq }
        var returningClient: Bool { _returningClient }

        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init() {
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func connect(host: String, port: UInt16, resume: UUID, lastReceivedSeq: Int64, handshakeTimeout: Duration) async throws {
            _sessionID = (resume == WireMessage.newSessionID) ? UUID() : resume
            _resumeFromSeq = lastReceivedSeq
            _returningClient = (resume != WireMessage.newSessionID)
        }
        func sendInput(_ bytes: Data) async throws {}
        func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16) async throws {}
        func sendAck(seq: Int64) async throws {}
        func sendBye() async throws {}
        func close() async { continuation.finish() }
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        func append(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() { lock.lock(); _value = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    }
}
