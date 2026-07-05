import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// Regression for the "switch tab thì mất toàn bộ history" report. A pane's SwiftUI `.task(id:)` re-fires
/// on every REMOUNT — including a mere pane remount when the user switches TABS — and used to call
/// `connect()` unconditionally, tearing down a healthy channel and wiping the terminal replay ring so the
/// pane came back blank. `ConnectionViewModel.connectIfNeeded()` is the idempotent guard: it dials only a
/// genuinely idle/dead channel and NO-OPS on a live/in-flight/supervised one, leaving the ring intact.
@MainActor
final class ConnectionViewModelConnectIfNeededTests: XCTestCase {
    /// Once CONNECTED, a `connectIfNeeded()` (the tab-switch remount path) must NOT re-dial (no new
    /// transport) and must NOT wipe the terminal replay ring — the prior screen has to survive the remount.
    func testConnectIfNeededNoOpsWhenAlreadyConnected() async {
        let rec = Recorder()
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal,
            target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(makeTransport: { rec.makeTransport() }) },
        )

        await vm.connect()
        XCTAssertEqual(vm.status, .connected)
        XCTAssertEqual(rec.count, 1, "the initial connect dials exactly one transport")

        // Accumulate some scrollback into the replay ring — this is the "history" the tab switch must keep.
        terminal.ingestOutput(Data("prior screen contents\n".utf8))
        let ringBefore = terminal.ringByteCount
        XCTAssertGreaterThan(ringBefore, 0)

        await vm.connectIfNeeded() // a tab switch remounts the pane and re-fires the `.task`

        XCTAssertEqual(vm.status, .connected, "a remount must not disturb a live channel")
        XCTAssertEqual(rec.count, 1, "connectIfNeeded must NOT re-dial when already connected")
        XCTAssertEqual(terminal.ringByteCount, ringBefore, "the replay ring (history) must survive the remount")
    }

    /// A genuinely idle channel (`.disconnected`) still dials on `connectIfNeeded()` — the initial mount
    /// path must keep working; only an ALREADY-live channel is skipped.
    func testConnectIfNeededDialsWhenDisconnected() async {
        let rec = Recorder()
        let vm = ConnectionViewModel(
            terminal: TerminalViewModel(),
            target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(makeTransport: { rec.makeTransport() }) },
        )
        XCTAssertEqual(vm.status, .disconnected)

        await vm.connectIfNeeded()

        XCTAssertEqual(vm.status, .connected, "an idle channel must dial on connectIfNeeded")
        XCTAssertEqual(rec.count, 1)
    }

    // MARK: - Immediate (non-gated) transport that connects on first call

    private actor ImmediateTransport: ClientTransporting {
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation

        init() {
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
        ) async {
            await Task.yield() // a non-throwing witness satisfies the throwing requirement; the yield is a
            _sessionID = UUID() // real suspension → a successful handshake → learned session id → .connected
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock()
            defer { lock.unlock() }
            return _count
        }

        func makeTransport() -> ImmediateTransport {
            lock.lock()
            _count += 1
            lock.unlock()
            return ImmediateTransport()
        }
    }
}
