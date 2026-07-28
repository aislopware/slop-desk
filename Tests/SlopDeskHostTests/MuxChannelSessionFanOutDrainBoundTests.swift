import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// The PTY-drain producer bound under FAN-OUT: who is allowed to pause the read loop, and who is not.
///
/// The single-subscriber drain sends INLINE, so `PausableQueueGate`'s enqueued-not-yet-sent
/// accounting bounds the pane at ``SlopDeskProtocol/MuxFlowControl/hostQueueCapacityBytes`` — the
/// PTY read loop stops, the kernel buffer fills, and the shell backpressures. Under fan-out the
/// drain hands each frame to per-member outboxes and dequeues immediately (it MUST — a serial
/// `await sub.data.send()` would give every member head-of-line over every other), so that source
/// can never assert. The bound therefore has to be re-derived from the FASTEST member's delivery
/// frontier: nobody is consuming ⇒ pause; somebody is ⇒ keep draining, and let
/// ``MuxChannelSession/subscriberLagBytes`` deal with the laggard.
///
/// Headless: unspawned ``PTYProcess`` (no read loop, no PTY), a recording ``PausableQueueGate``, and
/// the same `…ForTesting` producer seams the fan-out and backpressure suites use.
final class MuxChannelSessionFanOutDrainBoundTests: XCTestCase {
    // MARK: - Helpers

    private final class PauseRec: @unchecked Sendable {
        private let lock = NSLock()
        private var current = false
        private var everPaused = false
        func apply(_ paused: Bool) {
            lock.lock()
            current = paused
            if paused { everPaused = true }
            lock.unlock()
        }

        var isPaused: Bool { lock.lock()
            defer { lock.unlock() }
            return current
        }

        var didPause: Bool { lock.lock()
            defer { lock.unlock() }
            return everPaused
        }
    }

    /// Counts the wire bytes a sub-channel accepted — a member's delivery progress without decoding.
    private final class ByteSink: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func record(_ frame: Data) { lock.lock()
            total += frame.count
            lock.unlock()
        }

        var bytes: Int { lock.lock()
            defer { lock.unlock() }
            return total
        }
    }

    /// `window: nil` on a DATA channel = infinite send window: a member that always keeps up.
    /// A small value models a member whose peer grants no credit — its sender parks after one window.
    private func makeChannel(_ sink: ByteSink, kind: Channel, window: Int?) -> MuxSubChannel {
        MuxSubChannel(channelID: 1, channel: kind, sendWindowBytes: window) { _, frame in
            sink.record(frame)
        }
    }

    private let gateCapacity = 32 * 1024

    private func makeLiveSession(
        primaryWindow: Int?,
        primary: ByteSink,
        rec: PauseRec,
    ) -> MuxChannelSession {
        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — `startRelay` builds the drain, nothing reads a master fd
            data: makeChannel(primary, kind: .data, window: primaryWindow),
            control: makeChannel(ByteSink(), kind: .control, window: nil),
        )
        // AFTER `startRelay()`: it builds its own production-capacity gate wired to the read loop,
        // so an earlier install would be overwritten and every assertion here would read a gate
        // nothing drives.
        session.startRelay()
        session.installGateForTesting(PausableQueueGate(capacity: gateCapacity) { rec.apply($0) })
        return session
    }

    /// Feeds `chunks` × 16 KiB of PTY output through the REAL producer seam (gate accounting + FIFO
    /// + drain), yielding between chunks so the drain's task can run.
    private func feed(_ session: MuxChannelSession, chunks: Int) async {
        for index in 0..<chunks {
            session.enqueueChunkForTesting(bytes: Data(repeating: UInt8(0x41 + index % 26), count: 16 * 1024))
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The bound the inline path has always had

    /// CONTROL for the two fan-out cases below: with ONE member that never fanned out, a peer that
    /// grants no credit parks the drain inside its inline `send`, the out-FIFO fills, and the gate
    /// pauses the read loop. This is the behaviour the fan-out shape has to reproduce.
    func testTheInlineDrainPausesWhenItsOnlyMemberStopsConsuming() async {
        let rec = PauseRec()
        let primary = ByteSink()
        let session = makeLiveSession(primaryWindow: 16 * 1024, primary: primary, rec: rec)
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        XCTAssertFalse(session.isFannedOutForTesting, "precondition: one member ⇒ the inline path")

        await feed(session, chunks: 12)
        await waitUntil { rec.isPaused }
        XCTAssertTrue(
            rec.isPaused,
            "a lone member that grants no credit must backpressure the PTY at the queue bound",
        )
    }

    /// The other direction: the fan-out source must be INERT for a pane that never fanned out. With
    /// the queue bound raised well above what this feeds, a parked inline member is the out-FIFO's
    /// business alone — nothing else may pause the read loop on its behalf, or a one-client pane
    /// gets a bound it never had.
    func testTheInlineDrainIsBoundedByItsQueueAloneAndNothingElse() async {
        let rec = PauseRec()
        let primary = ByteSink()
        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(),
            data: makeChannel(primary, kind: .data, window: 16 * 1024),
            control: makeChannel(ByteSink(), kind: .control, window: nil),
        )
        session.startRelay()
        session.installGateForTesting(PausableQueueGate(capacity: 8 * 1024 * 1024) { rec.apply($0) })
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        await feed(session, chunks: 12)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(
            rec.didPause,
            "192 KiB parked behind an 8 MiB queue bound must not pause a pane that never fanned out",
        )
    }

    // MARK: - The bound must survive the fan-out

    /// THE ONE THAT BITES. A pane that fanned out and then shrinks back to one member — a laggard
    /// evicted, a second client closing its lid — still delivers through that member's OUTBOX, and
    /// the drain dequeues the gate the instant it hands a frame over. So the out-FIFO source cannot
    /// bound this pane, and `subscriberLagBytes` eviction cannot either (it never takes a pane to
    /// zero members): the fan-out backlog source is the ONLY thing standing between a stopped reader
    /// and a shell running flat out into host RAM, 4000× past the 64 KiB bound.
    func testTheDrainStillPausesAfterTheSetShrinksBackToOneMember() async {
        let rec = PauseRec()
        let primary = ByteSink()
        let session = makeLiveSession(primaryWindow: 16 * 1024, primary: primary, rec: rec)
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        // A second member joins on an infinite window, so its state transfer ships without parking.
        let joined = await session.joinSubscriber(
            data: makeChannel(ByteSink(), kind: .data, window: nil),
            control: makeChannel(ByteSink(), kind: .control, window: nil),
            sizePassive: false,
        )
        guard let joiner = joined else {
            XCTFail("a live pane must accept a join")
            return
        }
        XCTAssertTrue(session.isFannedOutForTesting, "precondition: two members ⇒ outbox delivery")

        // …and leaves again. ONE member holds the pane, delivered from its own outbox.
        XCTAssertFalse(session.removeSubscriber(joiner), "one of two leaving does not empty the set")
        XCTAssertEqual(session.subscriberCountForTesting, 1)

        await feed(session, chunks: 12)
        await waitUntil { rec.isPaused }
        XCTAssertTrue(
            rec.isPaused,
            "the last remaining member grants no credit, so the PTY drain must pause exactly as it "
                + "does on the inline path — otherwise the shell runs unbounded into host RAM",
        )
    }

    /// The other half, and the reason the bound cannot simply be "the slowest member": ONE laggard
    /// must never pause the drain for everybody. A member that keeps up holds the read loop open
    /// while the parked one falls behind — that is what `subscriberLagBytes` eviction is for.
    func testALaggardDoesNotPauseTheDrainWhileAnotherMemberKeepsUp() async {
        let rec = PauseRec()
        let fast = ByteSink()
        let session = makeLiveSession(primaryWindow: nil, primary: fast, rec: rec)
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        // Eviction is wired but deliberately unreachable at this volume — the drain has to keep
        // running on the laggard's own merit, not because the laggard was removed.
        session.onEvictSubscriber = { _ in XCTFail("no member is far enough behind to be evicted") }

        let laggard = ByteSink()
        let joined = await session.joinSubscriber(
            data: makeChannel(laggard, kind: .data, window: 8 * 1024),
            control: makeChannel(ByteSink(), kind: .control, window: nil),
            sizePassive: false,
        )
        XCTAssertNotNil(joined, "a live pane must accept a join")

        await feed(session, chunks: 12)
        await waitUntil { fast.bytes >= 12 * 16 * 1024 }
        XCTAssertGreaterThanOrEqual(
            fast.bytes, 12 * 16 * 1024,
            "the member that keeps up must receive every byte while the other is parked",
        )
        XCTAssertFalse(
            rec.didPause,
            "one parked member must never pause the PTY read loop — a sleeping phone cannot freeze "
                + "a running build for the Mac watching it",
        )
    }
}
