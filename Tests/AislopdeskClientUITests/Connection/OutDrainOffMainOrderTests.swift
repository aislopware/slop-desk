import AislopdeskProtocol
import AislopdeskTransport
import Foundation
import XCTest
@testable import AislopdeskClient
@testable import AislopdeskClientUI

/// The off-main OUT drain's load-bearing invariant: main-actor appends + ONE detached
/// consumer = wire order EXACTLY equals call order, even with per-send jitter on the
/// transport (the shape that scrambles unstructured Task-per-event sends). Also pins the
/// teardown contract: awaited drain completion → no interleave/duplication with the
/// residual flush, residual `.input` dropped, trailing `.resize` flushed.
@MainActor
final class OutDrainOffMainOrderTests: XCTestCase {
    func testKeystrokeOrderSurvivesJitteredTransportOffMain() async throws {
        let rec = JitterRecorder()
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal, target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { AislopdeskClient(makeTransport: { rec.makeTransport() }) },
        )
        await vm.connect()

        // 300 events in strict call order on the main actor, with resizes interleaved.
        var accumulated = Data()
        for i in 0..<300 {
            let byte = UInt8(i % 251)
            terminal.sendInput(Data([byte]))
            accumulated.append(byte)
            if i.isMultiple(of: 37) { terminal.sendResize(cols: UInt16(80 + i % 40), rows: 24) }
        }
        let expected = accumulated

        try await waitUntil(timeout: .seconds(10)) { rec.inputBytes == expected }
        XCTAssertEqual(
            rec.inputBytes,
            expected,
            "wire byte order == main-actor call order (single off-main consumer, no per-event Tasks)",
        )
        await vm.disconnect()
    }

    func testTeardownAwaitsDrainNoDuplicationAndFlushesTrailingResize() async {
        let rec = JitterRecorder()
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal, target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { AislopdeskClient(makeTransport: { rec.makeTransport() }) },
        )
        await vm.connect()

        for i in 0..<50 {
            terminal.sendInput(Data([UInt8(i)]))
        }
        terminal.sendResize(cols: 123, rows: 45)
        await vm.disconnect()

        // No duplication, order preserved for whatever was delivered (a teardown may drop
        // residual inputs by design — never reorder or duplicate them).
        let delivered = rec.inputBytes
        XCTAssertLessThanOrEqual(delivered.count, 50)
        XCTAssertEqual(
            delivered,
            Data((0..<UInt8(delivered.count)).map(\.self)),
            "delivered prefix is exactly the call-order prefix — no reorder, no duplicates",
        )
        XCTAssertEqual(rec.resizes.last?.cols, 123, "the trailing resize always reaches the host (control path)")
        XCTAssertEqual(rec.resizes.last?.rows, 45)
    }

    // MARK: - Jittering recording transport

    private final class JitterRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var sizes: [(cols: UInt16, rows: UInt16)] = []
        var inputBytes: Data { lock.lock()
            defer { lock.unlock() }
            return bytes
        }

        var resizes: [(cols: UInt16, rows: UInt16)] { lock.lock()
            defer { lock.unlock() }
            return sizes
        }

        func recordInput(_ d: Data) { lock.lock()
            bytes.append(d)
            lock.unlock()
        }

        func recordResize(_ c: UInt16, _ r: UInt16) { lock.lock()
            sizes.append((c, r))
            lock.unlock()
        }

        func makeTransport() -> JitterTransport { JitterTransport(recorder: self) }
    }

    private actor JitterTransport: ClientTransporting {
        private let recorder: JitterRecorder
        private var counter = 0
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init(recorder: JitterRecorder) {
            self.recorder = recorder
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func connect(
            host _: String,
            port _: UInt16,
            resume _: UUID,
            lastReceivedSeq _: Int64,
            handshakeTimeout _: Duration,
        ) {
            _sessionID = UUID()
        }

        func sendInput(_ bytes: Data) async {
            // Deterministic jitter: every 3rd send suspends, giving an unordered design
            // every opportunity to scramble. The single sequential drain must not.
            counter += 1
            if counter.isMultiple(of: 3) { try? await Task.sleep(for: .milliseconds(2)) }
            recorder.recordInput(bytes)
        }

        func sendResize(cols: UInt16, rows: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {
            recorder.recordResize(cols, rows)
        }

        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }

    private func waitUntil(timeout: Duration, _ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { throw OffMainOrderTestError.timedOut }
    }

    private enum OffMainOrderTestError: Error { case timedOut }
}
