import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// Regression for R-lifecycle #4: two overlapping `ConnectionViewModel.connect()` calls (a double / key-repeated
/// "Reconnect Pane") must be SERIALIZED, never interleaved. Before the single-flight chain, the second call's
/// teardown cancel-prefix ran before the first call built its client/observe/output tasks, so both handshakes
/// ran CONCURRENTLY and the first attempt's client survived as a supervised zombie painting into the pane.
/// With the fix the second attempt does not begin until the first fully completes, so at most ONE handshake is
/// in-flight at a time.
@MainActor
final class ConnectionViewModelSerializeTests: XCTestCase {
    func testConcurrentConnectsRunOneHandshakeAtATime() async {
        let rec = GateRecorder()
        let vm = ConnectionViewModel(
            terminal: TerminalViewModel(), target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(makeTransport: { rec.makeTransport() }) },
        )

        // Fire TWO connect() calls back-to-back (the double-Reconnect scenario).
        let t1 = Task { await vm.connect() }
        let t2 = Task { await vm.connect() }

        // The first attempt suspends in its handshake gate.
        await rec.waitForStarted(1)
        // Give the SECOND attempt ample room to (incorrectly, on the un-serialized code) start its own
        // concurrent handshake. Serialized, it is still blocked awaiting the first attempt → no 2nd transport.
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            rec.startedCountValue, 1,
            "serialized connect() must not run a second handshake while the first is still in flight",
        )

        // Release the first: it completes, THEN the second attempt begins (tearing the first's client down).
        await rec.releaseAll()
        await rec.waitForStarted(2)
        await rec.releaseAll()
        await t1.value
        await t2.value
    }

    // MARK: - Gated client transport (connect suspends until released)

    private actor GatedTransport: ClientTransporting {
        private let onStarted: @Sendable () -> Void
        private var gate: CheckedContinuation<Void, Error>?
        private var released = false
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init(onStarted: @escaping @Sendable () -> Void) {
            self.onStarted = onStarted
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
        ) async throws {
            if released { _sessionID = UUID()
                return
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.gate = c
                onStarted()
            }
            _sessionID = UUID()
        }

        func release() { released = true
            if let c = gate { gate = nil
                c.resume()
            }
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }

    private final class GateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [GatedTransport] = []
        private var startedCount = 0
        func makeTransport() -> GatedTransport {
            let t = GatedTransport(onStarted: { [weak self] in
                guard let self else { return }
                lock.lock()
                startedCount += 1
                lock.unlock()
            })
            lock.lock()
            transports.append(t)
            lock.unlock()
            return t
        }

        var startedCountValue: Int { lock.lock()
            defer { lock.unlock() }
            return startedCount
        }

        private func snapshot() -> [GatedTransport] { lock.lock()
            defer { lock.unlock() }
            return transports
        }

        func waitForStarted(_ n: Int) async {
            while startedCountValue < n { try? await Task.sleep(for: .milliseconds(2)) }
        }

        func releaseAll() async { for t in snapshot() { await t.release() } }
    }
}
