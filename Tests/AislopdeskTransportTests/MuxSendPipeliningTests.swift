import XCTest
import Foundation
import AislopdeskProtocol
@testable import AislopdeskTransport

/// Pins the two-tier send contract introduced for the terminal hot path: DATA frames ride
/// `MuxByteLink.sendPipelined` (synchronous enqueue, no per-frame dispatch round trip),
/// while in-flight bytes stay bounded by the per-channel credit window (debit-before-send)
/// and a pipelined write FAILURE routes into the LINK failure path (receiveChunks finishes
/// throwing → `finishLink` → `isDead`), exactly like a receive error.
final class MuxSendPipeliningTests: XCTestCase {

    /// Counts bytes handed to the link by pipelined sends — the receiver never grants, so
    /// the credit window is the ONLY bound. Without debit-before-send the flood would all
    /// reach the link at once.
    func testCreditWindowBoundsPipelinedFlood() async throws {
        final class CountingSink: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = 0
            func record(_ d: Data) { lock.lock(); bytes += d.count; lock.unlock() }
            var total: Int { lock.lock(); defer { lock.unlock() }; return bytes }
        }
        let sink = CountingSink()
        let window = 8 * 1024
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: window) { _, inner in
            sink.record(inner)   // synchronous record — models sendPipelined's enqueue
        }

        // Flood far past the window from one sender task (the production shape: a single
        // drain). It must park on the exhausted window with NO grants coming.
        let floodTask = Task {
            for _ in 0..<64 {
                try? await ch.send(WireMessage.output(seq: 1, bytes: Data(repeating: 0x61, count: 1024)))
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThanOrEqual(sink.total, window,
                                 "bytes handed to the link are bounded by the credit window even with pipelined (non-awaited) sends")
        XCTAssertGreaterThan(sink.total, 0, "the first window's worth of frames did flow")

        await ch.finish()   // wakes the parked sender (throws) so the task ends
        _ = await floodTask.value
    }

    /// A pipelined send failure must mark the shared connection DEAD via the link failure
    /// path (the same machinery a receive error drives) — pipelining swallows the per-call
    /// throw, so this path is the ONLY failure surfacing and must be provably wired.
    func testPipelinedSendFailureMarksConnectionDead() async throws {
        /// Receive stays silent (link looks alive); the FIRST pipelined send finishes the
        /// receive stream throwing — the documented NWMuxByteLink failure contract.
        final class PipelinedFailLink: MuxByteLink, @unchecked Sendable {
            private let stream: AsyncThrowingStream<Data, Error>
            private let continuation: AsyncThrowingStream<Data, Error>.Continuation
            init() {
                var c: AsyncThrowingStream<Data, Error>.Continuation!
                stream = AsyncThrowingStream { c = $0 }
                continuation = c
            }
            var receiveChunks: AsyncThrowingStream<Data, Error> { stream }
            func send(_ data: Data) async throws {}   // awaited sends (openChannel) succeed
            func sendPipelined(_ data: Data) {
                continuation.finish(throwing: AislopdeskTransportError.sendFailed("pipelined write failed (test)"))
            }
            func close() async {}
        }

        let (controlA, _) = InMemoryMuxLink.pair()
        let failingData = PipelinedFailLink()
        let client = MuxNWConnection(role: .client, controlLink: controlA, dataLink: failingData)
        await client.start()

        // openChannel succeeds (awaited send is fine); the first DATA frame rides
        // sendPipelined and kills the link.
        let pair = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        try? await pair.data.send(.input(Data("x".utf8)))

        // The receive loop observes the thrown finish → finishLink → isDead.
        try await pollUntil { await client.isDead }
        let dead = await client.isDead
        XCTAssertTrue(dead, "a pipelined write failure must surface on the link path and mark the connection dead")

        // The sub-channel's inbound must have ended throwing (the consumer-visible signal).
        var inboundThrew = false
        do {
            for try await _ in pair.data.inbound { }
        } catch {
            inboundThrew = true
        }
        XCTAssertTrue(inboundThrew, "the data sub-channel inbound finishes throwing after a pipelined send failure")

        await client.close()
    }

    private func pollUntil(timeout: Duration = .seconds(2), _ cond: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        if !(await cond()) { throw PipelineTestError.timedOut }
    }
    private enum PipelineTestError: Error { case timedOut }
}
