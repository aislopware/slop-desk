import AislopdeskProtocol
import AislopdeskTransport
import Foundation
import XCTest
@testable import AislopdeskClient

/// Focused unit test for the client-side dedup high-water mark
/// (`AislopdeskClient.deliverOutput`'s `guard seq > highestSeqFed`).
///
/// The e2e/reconnect tests prove no-gap/no-dup/in-order, but the *no-dup* result there is
/// produced by the HOST replay keying (`seq > lastReceivedSeq`) — the replayed tail is
/// always strictly new, so the client dedup branch is never exercised end-to-end. This
/// test drives inbound `output` directly through the client's real handling path so the
/// dedup branch is actually hit: feed seq 1,2,3 then replay 2,3,4 and assert `output`
/// yields bytes for 1,2,3,4 exactly once (the replayed 2,3 are dropped).
final class AislopdeskClientDedupTests: XCTestCase {
    func testDeliverOutputDropsAlreadyFedSeqs() async throws {
        // Inert transport factory: this test drives inbound via `handleInboundForTesting` and never
        // `connect()`s, so the factory is never invoked.
        let client = AislopdeskClient(makeTransport: {
            MuxClientTransport(
                acquire: { _, _, _, _ in throw AislopdeskTransportError.notConnected("inert test transport") },
                release: { _, _, _ in },
            )
        })

        // Collect the surfaced output bytes (wake + batch-drain, the consumer contract).
        let sink = ByteSink()
        let pump = Task {
            for await _ in client.outputWakeups {
                for chunk in await client.takeOutputBatch() { sink.append(chunk) }
            }
            for chunk in await client.takeOutputBatch() { sink.append(chunk) }
        }

        // Feed seq 1,2,3 (live), then a replayed tail 2,3,4 where 2,3 are duplicates of
        // what we already delivered and only 4 is new.
        let payloads: [Int64: Data] = [
            1: Data("a".utf8),
            2: Data("b".utf8),
            3: Data("c".utf8),
            4: Data("d".utf8),
        ]
        for seq in [1, 2, 3, 2, 3, 4] as [Int64] {
            try await client.handleInboundForTesting(.output(seq: seq, bytes: XCTUnwrap(payloads[seq])))
        }

        // Let the unbounded output stream flush the yielded chunks to the pump.
        try await waitUntil(timeout: .seconds(5)) { sink.bytes == Data("abcd".utf8) }

        // The replayed 2,3 must have been dropped: exactly a,b,c,d once each, in order.
        XCTAssertEqual(
            sink.bytes,
            Data("abcd".utf8),
            "dedup must drop the replayed seq 2,3 — each byte delivered exactly once, in order",
        )

        // Contiguous + dedup high-water marks both at 4 (we accepted 1..4, dropped re-sends).
        let contiguous = await client.highestContiguousSeq
        XCTAssertEqual(contiguous, 4, "highestContiguousSeq should reflect the 4 accepted outputs")

        pump.cancel()
        await client.close()
    }

    /// Audit finding #3 regression: on a real reconnect the mux host mints a BRAND-NEW shell whose
    /// output restarts at seq 1 (no per-channel resume). `AislopdeskClient.connect` must RESET the dedup
    /// high-water marks on every (re)connect — otherwise the fresh shell's seq-1 output is silently
    /// dropped as a "duplicate" against the dead session's stale `highestSeqFed`. The bug was that the
    /// reset was gated behind `!returningClient`, but `returningClient` is computed client-side as
    /// `resume != newSessionID` → ALWAYS true on reconnect → the reset was skipped exactly when needed.
    func testReconnectResetsDedupSoFreshShellOutputIsNotDropped() async throws {
        // A fresh fake per connect, replicating MuxClientTransport's identity logic faithfully:
        // returningClient = (resume != newSessionID), sessionID minted on a fresh resume.
        let client = AislopdeskClient(makeTransport: { FakeTransport() })

        let sink = ByteSink()
        let pump = Task {
            for await _ in client.outputWakeups {
                for chunk in await client.takeOutputBatch() { sink.append(chunk) }
            }
            for chunk in await client.takeOutputBatch() { sink.append(chunk) }
        }

        // ── Phase 1: first connect (fresh session) — drive seq 1,2,3 → high-water = 3.
        try await client.connect(host: "h", port: 1)
        for seq in [1, 2, 3] as [Int64] {
            await client.handleInboundForTesting(.output(seq: seq, bytes: Data("\(seq)".utf8)))
        }
        let afterPhase1 = await client.highestContiguousSeq
        XCTAssertEqual(afterPhase1, 3, "phase-1 delivered seq 1..3")

        // ── Phase 2: reconnect. client.sessionID is preserved → the fake reports returningClient=true
        // (exactly the real mux path). The fresh shell then emits seq 1 again.
        try await client.connect(host: "h", port: 1)
        await client.handleInboundForTesting(.output(seq: 1, bytes: Data("F".utf8)))

        let afterReconnect = await client.highestContiguousSeq
        XCTAssertEqual(
            afterReconnect, 1,
            "reconnect must RESET the dedup high-water so the fresh shell's seq-1 output is accepted "
                + "(without the fix it stays 3 and seq-1 is dropped as a stale duplicate)",
        )

        try await waitUntil(timeout: .seconds(5)) { sink.bytes == Data("123F".utf8) }
        XCTAssertEqual(
            sink.bytes,
            Data("123F".utf8),
            "the fresh shell's seq-1 byte 'F' is delivered after reconnect, not swallowed",
        )

        pump.cancel()
        await client.close()
    }

    // MARK: - Helpers

    /// Minimal `ClientTransporting` stub that mirrors `MuxClientTransport`'s session-identity rules
    /// (mint a UUID on a new resume; `returningClient = resume != newSessionID`) so `AislopdeskClient.connect`
    /// exercises its real reconnect branch. Inbound is an inert stream — the test drives `output`
    /// through `handleInboundForTesting` directly.
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

        func connect(
            host _: String,
            port _: UInt16,
            resume: UUID,
            lastReceivedSeq: Int64,
            handshakeTimeout _: Duration,
        ) {
            _sessionID = (resume == WireMessage.newSessionID) ? UUID() : resume
            _resumeFromSeq = lastReceivedSeq
            _returningClient = (resume != WireMessage.newSessionID)
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }

    private final class ByteSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock()
            data.append(d)
            lock.unlock()
        }

        var bytes: Data { lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private func waitUntil(timeout: Duration, _ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { throw AislopdeskDedupTestError.timedOut }
    }

    private enum AislopdeskDedupTestError: Error { case timedOut }
}
