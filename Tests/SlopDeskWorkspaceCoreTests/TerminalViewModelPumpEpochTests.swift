import Foundation
import SlopDeskClient
import XCTest
@testable import SlopDeskWorkspaceCore

/// Regression net for the output pump's epoch-snapshot timing (review finding): `observe()` must tag a
/// batch with the epoch of the session it was taken FROM (snapshot BEFORE the take), not whatever
/// `sessionEpoch` reads after `takeOutputBatch()` resumes. A reconnect (`markReconnecting()` → epoch bump
/// + fresh-wipe arm) runs on the same MainActor and can interleave while the pump is suspended in the
/// take; reading the epoch AFTER would tag the DEAD session's in-hand bytes with the NEW epoch, defeat
/// the ingestBatch guard, and let the dead bytes consume the fresh-session RIS wipe (stale output painted
/// under the new prompt). This drives the REAL pump with a driver that PARKS the first
/// `takeOutput` — the one point at which a batch is in hand and the main actor is still free — so
/// the interleave is deterministic, not racy.
@MainActor
final class TerminalViewModelPumpEpochTests: XCTestCase {
    private static let ris = Data([0x1B, 0x63]) // ESC c — the fresh-session wipe prefix.

    func testPumpTagsInHandBatchWithPreReconnectEpoch() async throws {
        let driver = FakePaneDriver()
        driver.gatesFirstTake = true
        let client = SlopDeskClient(driver: driver)
        try await client.connect(host: "h", port: 1)

        let surface = RecordingSurface()
        let model = TerminalViewModel(surface: surface)
        let pump = Task { await model.observe(client: client) }
        defer { pump.cancel() }

        // Deliver the DEAD session's bytes; the pump wakes, snapshots the epoch, and parks in the take.
        driver.deliverOutput(Data("DEAD".utf8))
        await waitUntil { driver.takeEntered }

        // The reconnect lands WHILE the dead batch is in hand: bump the epoch + arm the wipe.
        model.markReconnecting()
        driver.releaseTake()
        await megaYield()

        // The dead batch carried the PRE-reconnect epoch, so ingestBatch dropped it: nothing painted, and
        // the one-shot wipe is still armed for the real fresh session.
        XCTAssertEqual(surface.flushes, 0, "the dead in-hand batch must not paint after the reconnect")
        XCTAssertFalse(surface.writes.contains(Data("DEAD".utf8)), "dead bytes never reach the surface")

        // The fresh session's first output arrives on a LATER wake, taken under the bumped epoch: it
        // consumes the RIS wipe and paints — proving the wipe was preserved for it, not eaten by the dead batch.
        // A CONDITION wait, not a yield settle: the negative assertions above are the only ones a fixed
        // number of yields can express, because "nothing painted" has no arrival to wait for. This one
        // waits for an ARRIVAL, and how many yields the pump needs to get scheduled is a property of the
        // machine's load, not of the epoch tagging under test — 50 of them is enough on an idle box and
        // not enough beside a parallel `check`, which is how this read as a regression it was not.
        driver.deliverOutput(Data("FRESH".utf8))
        await waitUntil { surface.writes.contains(Data("FRESH".utf8)) }
        XCTAssertEqual(surface.writes.first, Self.ris, "the fresh session's first paint is preceded by the RIS wipe")
        XCTAssertTrue(surface.writes.contains(Data("FRESH".utf8)), "the fresh bytes paint")

        await client.close()
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @Sendable () -> Bool, tries: Int = 2000) async {
        for _ in 0..<tries {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func megaYield() async { for _ in 0..<50 { await Task.yield() } }

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
