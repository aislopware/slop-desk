import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// The off-main OUT drain's load-bearing invariant: main-actor appends + ONE detached
/// consumer = wire order EXACTLY equals call order, even with per-send jitter on the
/// transport (the shape that scrambles unstructured Task-per-event sends). Also pins the
/// teardown contract: awaited drain completion → no interleave/duplication with the
/// residual flush, residual `.input` dropped, trailing `.resize` flushed.
@MainActor
final class OutDrainOffMainOrderTests: XCTestCase {
    func testKeystrokeOrderSurvivesJitteredTransportOffMain() async throws {
        let rec = PaneDriverRecorder { driver in
            // Every third send stalls: an unordered design has every opportunity to scramble, and
            // the single sequential drain must not take it.
            driver.sendJitter = .milliseconds(2)
        }
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal, target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(driver: rec.make()) },
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
        let rec = PaneDriverRecorder { driver in
            // Every third send stalls: an unordered design has every opportunity to scramble, and
            // the single sequential drain must not take it.
            driver.sendJitter = .milliseconds(2)
        }
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal, target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(driver: rec.make()) },
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
