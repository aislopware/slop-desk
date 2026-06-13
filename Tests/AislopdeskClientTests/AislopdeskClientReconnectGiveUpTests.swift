import XCTest
import Foundation
import AislopdeskProtocol
import AislopdeskTransport
@testable import AislopdeskClient

/// Pins the reconnect campaign's give-up ceiling: a campaign against a host that never answers must
/// make EXACTLY ``ReconnectManager/maxReconnectAttempts`` connect attempts and then fire `onGaveUp`
/// once — no more, no fewer. This is the regression net for the cap unification (the per-pane campaign
/// once ran to 30 while the UI displayed a cap of 20; both now read the one constant).
final class AislopdeskClientReconnectGiveUpTests: XCTestCase {

    func testReconnectLoopGivesUpAfterExactlyMaxAttempts() async {
        let client = AislopdeskClient(makeTransport: { FailingTransport() })
        let logs = LineCollector()
        let gaveUp = GiveUpCounter()
        // A tiny backoff so the full campaign finishes in well under a second; the assertions (not a
        // wall-clock timeout) are what prove the count.
        await ReconnectManager.reconnectLoop(
            client: client, host: "h", port: 1,
            backoff: .init(initial: .microseconds(1), maximum: .microseconds(2), multiplier: 2.0),
            onLog: { logs.append($0) },
            onProgress: { _, _ in },
            onGaveUp: { gaveUp.bump() }
        )

        let failedCount = logs.lines.filter { $0.contains("failed") }.count
        XCTAssertEqual(failedCount, ReconnectManager.maxReconnectAttempts,
                       "exactly maxReconnectAttempts connect attempts are made before giving up")
        XCTAssertEqual(gaveUp.value, 1, "onGaveUp fires exactly once at the end of the campaign")
        XCTAssertTrue(
            logs.lines.contains { $0.contains("gave up after \(ReconnectManager.maxReconnectAttempts)") },
            "the give-up log names the real campaign length"
        )
        await client.close()
    }

    // MARK: - Helpers

    /// A transport whose `connect` always throws, so every reconnect attempt fails — driving the loop to
    /// its give-up ceiling. A thrown connect does NOT close the client (AislopdeskClient.connect rethrows
    /// without setting `closed`), so the loop keeps retrying until the cap.
    private actor FailingTransport: ClientTransporting {
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        var sessionID: UUID? { nil }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }

        init() {
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        struct Refused: Error {}
        func connect(host: String, port: UInt16, resume: UUID, lastReceivedSeq: Int64, handshakeTimeout: Duration) async throws {
            throw Refused()
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

    private final class GiveUpCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func bump() { lock.lock(); _value += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    }
}
