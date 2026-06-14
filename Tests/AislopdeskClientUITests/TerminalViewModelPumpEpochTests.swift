import AislopdeskClient
import AislopdeskProtocol
import AislopdeskTerminal
import AislopdeskTransport
import Foundation
import XCTest
@testable import AislopdeskClientUI

/// Regression net for the output pump's epoch-snapshot timing (review finding): `observe()` must tag a
/// batch with the epoch of the session it was taken FROM (snapshot BEFORE the take), not whatever
/// `sessionEpoch` reads after `takeOutputBatch()` resumes. A reconnect (`markReconnecting()` → epoch bump
/// + fresh-wipe arm) runs on the same MainActor and can interleave while the pump is suspended in the
/// take; reading the epoch AFTER would tag the DEAD session's in-hand bytes with the NEW epoch, defeat
/// the ingestBatch guard, and let the dead bytes consume the fresh-session RIS wipe (stale output painted
/// under the new prompt). This drives the REAL pump with a transport that gates `noteOutputConsumed`
/// (the suspension point inside `takeOutputBatch`), so the interleave is deterministic, not racy.
@MainActor
final class TerminalViewModelPumpEpochTests: XCTestCase {
    private static let ris = Data([0x1B, 0x63]) // ESC c — the fresh-session wipe prefix.

    func testPumpTagsInHandBatchWithPreReconnectEpoch() async throws {
        let transport = GatedTransport()
        let client = AislopdeskClient(makeTransport: { transport })
        try await client.connect(host: "h", port: 1)

        let surface = RecordingSurface()
        let model = TerminalViewModel(surface: surface)
        let pump = Task { await model.observe(client: client) }
        defer { pump.cancel() }

        // Deliver the DEAD session's bytes; the pump wakes, snapshots the epoch, and suspends in the take
        // (gated at noteOutputConsumed).
        transport.deliver(.output(seq: 1, bytes: Data("DEAD".utf8)))
        await waitUntil { await transport.hasEntered() }

        // The reconnect lands WHILE the dead batch is in hand: bump the epoch + arm the wipe.
        model.markReconnecting()
        await transport.release()
        await megaYield()

        // The dead batch carried the PRE-reconnect epoch, so ingestBatch dropped it: nothing painted, and
        // the one-shot wipe is still armed for the real fresh session.
        XCTAssertEqual(surface.flushes, 0, "the dead in-hand batch must not paint after the reconnect")
        XCTAssertFalse(surface.writes.contains(Data("DEAD".utf8)), "dead bytes never reach the surface")

        // The fresh session's first output arrives on a LATER wake, taken under the bumped epoch: it
        // consumes the RIS wipe and paints — proving the wipe was preserved for it, not eaten by the dead batch.
        transport.deliver(.output(seq: 2, bytes: Data("FRESH".utf8)))
        await megaYield()
        XCTAssertEqual(surface.writes.first, Self.ris, "the fresh session's first paint is preceded by the RIS wipe")
        XCTAssertTrue(surface.writes.contains(Data("FRESH".utf8)), "the fresh bytes paint")

        await client.close()
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @Sendable () async -> Bool, tries: Int = 200) async {
        for _ in 0..<tries {
            if await condition() { return }
            await Task.yield()
        }
    }

    private func megaYield() async { for _ in 0..<50 { await Task.yield() } }

    /// A transport whose `noteOutputConsumed` (the suspension point inside `takeOutputBatch`) blocks on a
    /// one-shot gate the first time it is hit, so the test can interleave `markReconnecting()` at exactly
    /// the moment the dead batch is in hand. Subsequent takes (the fresh session) pass through.
    private actor GatedTransport: ClientTransporting {
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }

        private var gateArmed = true
        private var entered = false
        private var released = false

        init() {
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        nonisolated func deliver(_ message: WireMessage) { continuation.yield(message) }
        func hasEntered() -> Bool { entered }
        func release() { released = true }

        func connect(
            host _: String,
            port _: UInt16,
            resume: UUID,
            lastReceivedSeq _: Int64,
            handshakeTimeout _: Duration,
        ) {
            _sessionID = (resume == WireMessage.newSessionID) ? UUID() : resume
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { released = true
            continuation.finish()
        }

        func noteOutputConsumed(wireBytes _: Int) async {
            guard gateArmed else { return }
            gateArmed = false
            entered = true
            while !released { await Task.yield() } // hold the take open until the test interleaves the reconnect
        }
    }

    private final class RecordingSurface: TerminalSurface, @unchecked Sendable {
        var writes: [Data] = []
        var flushes = 0
        func feed(_ bytes: Data) { writes.append(bytes)
            flushes += 1
        }

        func feedBatch(_ chunks: ArraySlice<Data>) { writes.append(contentsOf: chunks)
            flushes += 1
        }

        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}
        var onWrite: ((Data) -> Void)?
    }
}
