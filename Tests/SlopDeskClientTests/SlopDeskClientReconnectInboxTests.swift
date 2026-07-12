import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskClient

/// The reconnect reset branch (`resumeFromSeq == 0`, which the mux path takes on EVERY connect —
/// the openAck carries only `accepted: Bool`) must not `outputInbox.removeAll()`: that would
/// discard bytes that have ARRIVED over the wire but have not yet been CONSUMED by the UI
/// (`takeOutputBatch`). Those bytes are already claimed to the host: `deliverOutput` advances
/// `highestContiguousSeq` at wire-arrival time, and `connect()` presents it as `lastReceivedSeq`
/// — so on a genuine PATH-A reattach the host never resends them. Wiping the client's only copy
/// would make the loss silent and permanent: a scrollback gap exactly at the reconnect boundary.
///
/// The fix keeps the undelivered bytes across the reset (they are the tail of what the old life
/// produced, valid for both PATH A reattach and PATH B fresh-shell-with-kept-grid) and zeroes
/// their wire-credit so `takeOutputBatch` can never emit a phantom `windowAdjust` over-grant on
/// the NEW channel (whose peer never sent those bytes — the original reason for the wipe).
final class SlopDeskClientReconnectInboxTests: XCTestCase {
    func testReconnectKeepsUnconsumedInboxBytesAndCreditsZeroForThem() async throws {
        let transports = TransportBox()
        let client = SlopDeskClient(makeTransport: {
            let t = CreditRecordingFakeTransport()
            transports.append(t)
            return t
        })

        // ── Phase 1: connect; the host streams seq 1..3 — but the UI consumer never drains
        // (no pump): the bytes sit in `outputInbox` while `highestContiguousSeq` is already 3.
        try await client.connect(host: "h", port: 1)
        for (seq, byte) in [(Int64(1), "a"), (2, "b"), (3, "c")] {
            await client.handleInboundForTesting(.output(seq: seq, bytes: Data(byte.utf8)))
        }
        let claimed = await client.highestContiguousSeq
        XCTAssertEqual(claimed, 3, "precondition: the bytes were claimed to the host at arrival time")

        // ── Phase 2: reconnect (link blip). The client presents lastReceivedSeq=3, so a
        // reattaching host will never resend seq ≤ 3 — the inbox copy is the ONLY copy.
        try await client.connect(host: "h", port: 1)

        // Fresh life's first output (the reset branch zeroed the dedup marks).
        await client.handleInboundForTesting(.output(seq: 1, bytes: Data("F".utf8)))

        // The consumer finally drains: the pre-reconnect tail must still be there, in order,
        // ahead of the new life's output.
        let batch = await client.takeOutputBatch()
        let joined = batch.reduce(Data()) { $0 + $1 }
        XCTAssertEqual(
            joined, Data("abcF".utf8),
            "un-consumed pre-reconnect output must survive the reconnect reset — "
                + "the host will never resend it (lastReceivedSeq already claimed it)",
        )

        // Credit hygiene (the original reason for the wipe): the carried-over entries must
        // credit ZERO wire bytes to the NEW transport — only the new life's `F` frame counts.
        XCTAssertEqual(transports.all.count, 2, "one transport per connect")
        let fWireBytes = WireMessage.output(seq: 1, bytes: Data("F".utf8)).wireByteCount
        let creditedToNew = await transports.all[1].credited
        XCTAssertEqual(
            creditedToNew, fWireBytes,
            "carried-over bytes must not emit a phantom windowAdjust over-grant on the new channel",
        )

        await client.close()
    }

    // MARK: - Helpers

    /// Mirrors `MuxClientTransport`'s identity rules (mint a UUID on a fresh resume;
    /// `resumeFromSeq = 0` always — the mux openAck carries no host-authoritative seq) and
    /// RECORDS every `noteOutputConsumed` credit so the test can assert credit hygiene.
    private actor CreditRecordingFakeTransport: ClientTransporting {
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { _returning }
        private var _returning = false
        private(set) var credited = 0

        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init() {
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func connect(
            host _: String,
            port _: UInt16,
            resume: UUID,
            lastReceivedSeq _: Int64,
            handshakeTimeout _: Duration,
        ) {
            _sessionID = (resume == WireMessage.newSessionID) ? UUID() : resume
            _returning = (resume != WireMessage.newSessionID)
        }

        func noteOutputConsumed(wireBytes: Int) { credited += wireBytes }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }

    private final class TransportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [CreditRecordingFakeTransport] = []
        func append(_ t: CreditRecordingFakeTransport) { lock.lock()
            transports.append(t)
            lock.unlock()
        }

        var all: [CreditRecordingFakeTransport] { lock.lock()
            defer { lock.unlock() }
            return transports
        }
    }
}
