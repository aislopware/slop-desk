import Foundation
import XCTest
@testable import SlopDeskTransport

/// The half-paired mux reaper: a CONTROL (or DATA) socket arrives, its partner never does, and the
/// parked link's fd must not leak.
///
/// `HostTransport` has carried the seams for this since the reaper was written — `pendingCount()`,
/// `isPending(_:)`, `reapExpiredPending(now:)`, `instantNowForTest()`,
/// `instantPastAllPendingDeadlines()` — each documented as "called directly by tests with a
/// synthesized `now` so the behaviour is verified WITHOUT any wall-clock sleep". No test called any
/// of them: the only way to park an entry was `associateMux(_ connection:…)`, which takes an
/// `NWConnection`, and this suite opens no sockets (a real listener hangs the test process). So the
/// bound on a hostile CONTROL-only flood — the reason the reaper exists — was asserted by a doc
/// comment and nothing else. `associateMux(link:connectionID:isControl:)` is the way in.
final class HostTransportPendingReaperTests: XCTestCase {
    /// A ``MuxByteLink`` that does nothing but remember whether it was closed. The reaper's whole
    /// job is closing the parked side, so that one bit is the entire assertion surface here.
    private final class CloseCountingMuxLink: MuxByteLink, @unchecked Sendable {
        private let lock = NSLock()
        private var closes = 0

        var closeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return closes
        }

        var receiveChunks: AsyncThrowingStream<Data, Error> { AsyncThrowingStream { _ in } }
        func send(_: Data) {}
        func sendPipelined(_: Data) {}
        /// Synchronous, like the sibling fixtures: a sync method witnesses the protocol's `async`
        /// requirement, and `NSLock` is unavailable from an `async` body.
        func close() {
            lock.lock()
            closes += 1
            lock.unlock()
        }
    }

    /// A lone CONTROL half parks, survives a reap stamped at the CURRENT instant, and is closed +
    /// dropped by one stamped past its deadline. Both stamps come from the transport's own clock, so
    /// the test never sleeps and never depends on how loaded the machine is.
    func testAHalfPairIsReapedOnlyOnceItsDeadlineHasPassed() async {
        let transport = HostTransport(pendingDataTimeout: .seconds(15))
        let control = CloseCountingMuxLink()
        let id = UUID()

        await transport.associateMux(link: control, connectionID: id, isControl: true)
        var pending = await transport.pendingCount()
        XCTAssertEqual(pending, 1)
        var isPending = await transport.isPending(id)
        XCTAssertTrue(isPending)

        // A young entry is not reaped early — the reaper must bound the leak, not close live
        // half-pairs whose partner is merely slow.
        await transport.reapExpiredPending(now: transport.instantNowForTest())
        pending = await transport.pendingCount()
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(control.closeCount, 0)

        await transport.reapExpiredPending(now: transport.instantPastAllPendingDeadlines())
        pending = await transport.pendingCount()
        XCTAssertEqual(pending, 0)
        isPending = await transport.isPending(id)
        XCTAssertFalse(isPending)
        await Self.settle()
        XCTAssertEqual(control.closeCount, 1, "the parked link's fd is released by the reaper")
    }

    /// The partner arrives: the pair completes, nothing stays parked, and neither link is closed.
    func testTheArrivingPartnerCompletesThePairAndLeavesNothingParked() async {
        let transport = HostTransport()
        let control = CloseCountingMuxLink()
        let data = CloseCountingMuxLink()
        let id = UUID()

        await transport.associateMux(link: control, connectionID: id, isControl: true)
        await transport.associateMux(link: data, connectionID: id, isControl: false)

        let pending = await transport.pendingCount()
        XCTAssertEqual(pending, 0)
        let isPending = await transport.isPending(id)
        XCTAssertFalse(isPending)
        await Self.settle()
        XCTAssertEqual(control.closeCount, 0)
        XCTAssertEqual(data.closeCount, 0)
    }

    /// A SECOND socket for a side that is already parked — two CONTROLs before any DATA shows — closes
    /// the displaced link rather than overwriting it, and does NOT restamp the deadline.
    ///
    /// Both halves matter and they fail differently. Overwriting leaks one fd per duplicate, invisible
    /// to a reaper that only sees the current map entry. Restamping is worse: a peer re-sending the
    /// same side in a loop pushes the deadline out forever, so the entry is never reaped at all and the
    /// bound this whole mechanism provides evaporates while `pendingCount()` still reads a reassuring 1.
    ///
    /// The deadline half is asserted with a real elapsed wait rather than a synthesized instant,
    /// because the discriminating question is which `createdAt` the entry kept — and the test cannot
    /// read it. A tiny timeout plus a wait past it makes the assertion one-sided: a slower machine only
    /// ages the entry further, so a preserved `createdAt` reaps under any load, and only a RESTAMPED
    /// one can fail it.
    func testARepeatedSameSideHalfClosesTheDisplacedLinkAndKeepsTheOriginalDeadline() async throws {
        let timeout = Duration.milliseconds(50)
        let transport = HostTransport(pendingDataTimeout: timeout)
        let first = CloseCountingMuxLink()
        let second = CloseCountingMuxLink()
        let id = UUID()

        await transport.associateMux(link: first, connectionID: id, isControl: true)
        try await Task.sleep(for: timeout * 2)
        await transport.associateMux(link: second, connectionID: id, isControl: true)

        let pending = await transport.pendingCount()
        XCTAssertEqual(pending, 1, "the duplicate re-parks in place — it does not add an entry")
        await Self.settle()
        XCTAssertEqual(first.closeCount, 1, "the displaced half is closed, not silently dropped")
        XCTAssertEqual(second.closeCount, 0)

        // `createdAt` was preserved, so the entry is already past its deadline at the CURRENT instant.
        await transport.reapExpiredPending(now: transport.instantNowForTest())
        let afterReap = await transport.pendingCount()
        XCTAssertEqual(afterReap, 0, "a re-park must not defer the reaper's deadline")
        await Self.settle()
        XCTAssertEqual(second.closeCount, 1)
    }

    /// After `stop()`, a link that arrives is closed on the spot and never parked — the drained map
    /// has no owner left to close it, so parking one is a leak with no reaper behind it.
    func testALinkArrivingAfterStopIsClosedAndNeverParked() async {
        let transport = HostTransport()
        let late = CloseCountingMuxLink()

        await transport.stop()
        await transport.associateMux(link: late, connectionID: UUID(), isControl: true)

        let pending = await transport.pendingCount()
        XCTAssertEqual(pending, 0)
        await Self.settle()
        XCTAssertEqual(late.closeCount, 1)
    }

    /// `stop()` drains whatever is still parked, closing both sides — the fd-exhaustion guard for a
    /// menu-bar host that is started and stopped repeatedly.
    func testStopDrainsAndClosesEveryParkedHalf() async {
        let transport = HostTransport()
        let control = CloseCountingMuxLink()
        let data = CloseCountingMuxLink()

        await transport.associateMux(link: control, connectionID: UUID(), isControl: true)
        await transport.associateMux(link: data, connectionID: UUID(), isControl: false)
        var pending = await transport.pendingCount()
        XCTAssertEqual(pending, 2)

        await transport.stop()
        pending = await transport.pendingCount()
        XCTAssertEqual(pending, 0)
        await Self.settle()
        XCTAssertEqual(control.closeCount, 1)
        XCTAssertEqual(data.closeCount, 1)
    }

    /// Every close in `HostTransport` is dispatched as a detached `Task`, so the actor call returns
    /// before the link has observed it. One yield-and-brief-wait is enough to let those tasks run;
    /// it is bounded and never conditional, so a failure here is a real one, not a timeout.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}
