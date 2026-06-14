import AislopdeskProtocol
import AislopdeskTransport
import Foundation
import XCTest
@testable import AislopdeskClient
@testable import AislopdeskClientUI

/// Regression for R6 #1: `ConnectionViewModel.connect()`/`resume()` must NOT whitewash a torn-down or
/// superseded pane to `.connected`. Because `AislopdeskClient.connect` now RETURNS (not throws) when it was
/// closed/paused/superseded mid-handshake (the R5 zombie-transport fix), the VM's `do` success branch
/// would otherwise set `status = .connected` (+ overwrite `sessionID`) for a pane the user already
/// disconnected. The fix: a `connectGeneration` + `self.client === client` identity guard before the
/// post-await writes. Looped to shake the interleaving.
@MainActor
final class ConnectionViewModelSupersedeTests: XCTestCase {
    /// A `disconnect()` landing while `connect()` is suspended in the handshake must leave the pane
    /// `.disconnected`, never `.connected`.
    func testDisconnectDuringInflightConnectStaysDisconnected() async {
        for _ in 0..<120 {
            let rec = GateRecorder()
            let vm = ConnectionViewModel(
                terminal: TerminalViewModel(), target: { ConnectionTarget(host: "h", port: 1) },
                makeClient: { AislopdeskClient(makeTransport: { rec.makeTransport() }) },
            )
            let connectTask = Task { await vm.connect() }
            await rec.waitForStarted(1) // connect() is suspended in the handshake gate
            await vm.disconnect() // the user closes the pane mid-handshake
            await rec.releaseAll() // let the handshake complete + connect() resume
            await connectTask.value

            XCTAssertEqual(
                vm.status,
                .disconnected,
                "a disconnect during the in-flight connect must NOT be whitewashed to .connected",
            )
        }
    }

    /// R13 #3: a LATE `.reconnected` event — drained from the broadcaster buffer AFTER a deliberate
    /// `disconnect()` (a buffered AsyncStream element is delivered even post-cancel/finish) — must NOT
    /// whitewash the closed pane back to green `.connected`. Folded synchronously via the DEBUG hook.
    func testLateReconnectedAfterDisconnectStaysDisconnected() async {
        let vm = ConnectionViewModel(
            terminal: TerminalViewModel(), target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { AislopdeskClient(makeTransport: { fatalError("never connected in this test") }) },
        )
        await vm.disconnect() // deliberatelyClosed = true; status = .disconnected (never connected)
        XCTAssertEqual(vm.status, .disconnected)

        vm.foldEventForTesting(.reconnected(sessionID: UUID(), resumeFromSeq: 0))
        XCTAssertEqual(
            vm.status,
            .disconnected,
            "a late .reconnected after a deliberate disconnect must not flip the pane to .connected",
        )
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

        private func started() -> Int { lock.lock()
            defer { lock.unlock() }
            return startedCount
        }

        private func snapshot() -> [GatedTransport] { lock.lock()
            defer { lock.unlock() }
            return transports
        }

        func waitForStarted(_ n: Int) async {
            while started() < n { try? await Task.sleep(for: .milliseconds(2)) }
        }

        func releaseAll() async { for t in snapshot() { await t.release() } }
    }
}
