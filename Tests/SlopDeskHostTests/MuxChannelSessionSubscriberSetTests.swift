import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// The pane's reader is a SET — with exactly one member.
///
/// ``MuxChannelSession`` holds its client half as `subscribers: [MuxSubscriberID: Subscriber]`
/// instead of a bare `data`/`control` pair. N is 1, so every assertion here is simultaneously a
/// statement about the shipping single-client path: the session opens with one member, a reattach
/// REPLACES that member (it never grows the set), the incumbent's channels go quiet, and the
/// session-wide teardown runs exactly when the set EMPTIES.
///
/// Headless: unspawned ``PTYProcess``, no read loop — the producer side is driven through the same
/// `…ForTesting` seams the drain-merge and detach/reattach suites use.
final class MuxChannelSessionSubscriberSetTests: XCTestCase {
    // MARK: - Helpers

    /// Decodes every framed byte a sub-channel's `muxSend` writes back into ``WireMessage``s.
    private final class SendRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let decoder = FrameDecoder()
        private var messages: [WireMessage] = []

        func record(_ innerFrame: Data) {
            lock.lock()
            defer { lock.unlock() }
            decoder.append(innerFrame)
            while let message = (try? decoder.nextMessage()) { messages.append(message) }
        }

        var all: [WireMessage] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }

        var outputBytes: Data {
            lock.lock()
            defer { lock.unlock() }
            var joined = Data()
            for message in messages {
                if case let .output(_, bytes) = message { joined.append(bytes) }
            }
            return joined
        }
    }

    private final class ObservedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (wake: Bool, count: Int)?
        func set(_ value: (wake: Bool, count: Int)) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: (wake: Bool, count: Int)? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func makeSession(
        data: MuxSubChannel,
        control: MuxSubChannel,
    ) -> MuxChannelSession {
        MuxChannelSession(channelID: 1, pty: PTYProcess(), data: data, control: control)
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The set starts at one

    /// `init(data:control:)` seeds subscriber #1. The seed happens at INIT, not at `startRelay()`:
    /// the detach/reattach suites drive `detach()` on a session that never started a relay, and a
    /// session with no member there would have nothing to retire.
    func testTheSessionOpensHoldingExactlyOneSubscriber() {
        let session = makeSession(
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
        XCTAssertEqual(
            session.subscriberCountForTesting, 1,
            "the channel this session was opened for IS the set's first member",
        )
    }

    // MARK: - A reattach REPLACES, it does not grow

    /// The one-subscriber special case of a join: rebinding onto a returning client's channels
    /// leaves the set at ONE member, and the incumbent's channels fall silent (the retired
    /// subscriber's tasks and control wake are gone with it).
    func testRebindReplacesTheIncumbentInsteadOfGrowingTheSet() async {
        let oldData = SendRecorder()
        let oldControl = SendRecorder()
        let session = makeSession(
            data: MuxSubChannel(channelID: 1, channel: .data) { _, frame in oldData.record(frame) },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, frame in oldControl.record(frame) },
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.startRelay()
        session.detach(onDetachedExit: { _ in })

        let newData = SendRecorder()
        let newControl = SendRecorder()
        let dataChannel = MuxSubChannel(channelID: 1, channel: .data) { _, frame in newData.record(frame) }
        let controlChannel = MuxSubChannel(channelID: 1, channel: .control) { _, frame in
            newControl.record(frame)
        }
        XCTAssertTrue(session.rebindRelay(data: dataChannel, control: controlChannel, onExit: nil))

        XCTAssertEqual(
            session.subscriberCountForTesting, 1,
            "a reattach REPLACES the one member — the set must not grow behind the shipping path",
        )

        let bytesBeforeRebind = oldData.outputBytes.count
        session.enqueueChunkForTesting(bytes: Data("after-rebind\n".utf8), control: [.title("t")])
        await waitUntil { newData.outputBytes == Data("after-rebind\n".utf8) }
        XCTAssertEqual(
            newData.outputBytes, Data("after-rebind\n".utf8),
            "the surviving subscriber's DATA channel carries the pane's output",
        )
        await waitUntil { newControl.all.contains(.title("t")) }
        XCTAssertTrue(newControl.all.contains(.title("t")), "and its CONTROL channel carries the sniffed control")
        XCTAssertEqual(
            oldData.outputBytes.count, bytesBeforeRebind,
            "the retired subscriber's DATA channel must go quiet — nothing may still be pinned to it",
        )
        XCTAssertFalse(
            oldControl.all.contains(.title("t")),
            "the retired subscriber's CONTROL channel must go quiet too",
        )

        session.pty.completeExitForTesting(code: 0)
        session.shutdownDetached()
    }

    /// `PTYProcess.waitForExit()` parks a plain `CheckedContinuation` with no cancellation
    /// plumbing, so a second registration is never retired: joining a subscriber must NOT touch
    /// `exitTask`. Only `startRelay()` ever mints one.
    func testJoiningASubscriberNeverMintsASecondExitWaiter() {
        let session = makeSession(
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        XCTAssertFalse(session.hasExitTaskForTesting, "precondition: no startRelay → no exit task")

        for cycle in 1...3 {
            session.detach(onDetachedExit: { _ in })
            XCTAssertTrue(session.rebindRelay(
                data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
                control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
                onExit: nil,
            ))
            XCTAssertEqual(session.subscriberCountForTesting, 1, "cycle \(cycle): still exactly one member")
            XCTAssertFalse(
                session.hasExitTaskForTesting,
                "cycle \(cycle): a join must not register a second PTY exit waiter (duplicate .exit frame)",
            )
        }
    }

    // MARK: - The teardown belongs to the set EMPTYING

    /// `detach()` retires the one member and then runs the session-wide teardown, because the set
    /// is now empty: the output drain stops, so bytes produced while away stay in the out-FIFO
    /// (they were never sequenced into the ReplayBuffer) instead of being shipped at a dead client.
    func testDetachEmptiesTheSetAndStopsTheSessionWideDrain() async {
        let oldData = SendRecorder()
        let session = makeSession(
            data: MuxSubChannel(channelID: 1, channel: .data) { _, frame in oldData.record(frame) },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.startRelay()
        XCTAssertEqual(session.subscriberCountForTesting, 1, "precondition: one member")

        session.detach(onDetachedExit: { _ in })
        XCTAssertEqual(
            session.subscriberCountForTesting, 0,
            "detaching the only subscriber empties the set",
        )
        XCTAssertFalse(
            session.hasControlWakeContinuationForTesting,
            "the retired member's control wake goes with it — an enqueue now has nobody to wake",
        )

        session.enqueueChunkForTesting(bytes: Data("while-away\n".utf8))
        // Give a (wrongly) surviving drain time to ship the chunk at the dead client.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(
            oldData.outputBytes, Data(),
            "the session-wide drain must be cancelled once the set empties — while-away bytes stay "
                + "in the out-FIFO for the returning client (they are not in the ReplayBuffer)",
        )
    }

    // MARK: - Per-subscriber ordering: control sender BEFORE the output drain

    /// The restarted drain's first act on a detached backlog is `takeMergedFrame()` → hand the
    /// sniffed control to the control queue. So the joining subscriber's control sender + wake must
    /// already exist when the drain can first run — pinned structurally at the earliest instant the
    /// drain can be scheduled, together with the fact that the member is already installed by then.
    func testJoiningSubscribersControlWakeExistsBeforeTheDrainCanRun() {
        let session = makeSession(
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.detach(onDetachedExit: { _ in })
        session.enqueueChunkForTesting(bytes: Data("away\n".utf8), control: [.title("away-title")])

        let observed = ObservedBox()
        session.onOutputDrainRestartedForTesting = { [weak session] in
            observed.set((
                wake: session?.hasControlWakeContinuationForTesting ?? false,
                count: session?.subscriberCountForTesting ?? -1,
            ))
        }
        XCTAssertTrue(session.rebindRelay(
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            onExit: nil,
        ))
        session.onOutputDrainRestartedForTesting = nil

        XCTAssertEqual(observed.value?.count, 1, "the joining member is installed before the drain can run")
        XCTAssertEqual(
            observed.value?.wake, true,
            "its control sender + wake are built BEFORE the output drain is created and kicked — "
                + "otherwise a detached-window title lands in the member's queue with no wake",
        )
    }
}
