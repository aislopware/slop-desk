import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// A REQUEST-SCOPED reply goes back to the peer that asked — never to the pane at large.
///
/// Three of the session's control emissions are answers to a specific frame on a specific
/// sub-channel: `.pong` echoes ONE client's clock stamp, `.blockOutput` answers ONE
/// `requestBlockOutput`, and `.metadataResponse` answers ONE `metadataRequest` whose `requestID`
/// comes from a PER-CLIENT counter starting at 1. Broadcasting any of them would pop another
/// client's pending waiter and hand it a foreign payload, or fold a foreign clock stamp into an RTT
/// reading. Credit is the same shape: it must be returned on the DATA channel the input arrived on,
/// because each ``MuxSubChannel`` owns its own receive window and a sender parked on an exhausted
/// window is only ever woken by a grant on ITS channel.
///
/// N is 1 today, so every route lands on the same member — which is exactly why these assertions
/// are written against the channel PAIR that received the request: a reply resolved from the wrong
/// member is visible here the moment a reattach swaps the pair.
final class MuxChannelSessionReplyRoutingTests: XCTestCase {
    // MARK: - Helpers

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
    }

    /// Records every `noteConsumed` byte-count a DATA sub-channel reports to its owner — the
    /// credit-at-consumption sink the real ``MuxNWConnection`` feeds into its receive accountant.
    private final class CreditRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func add(_ bytes: Int) {
            lock.lock()
            total += bytes
            lock.unlock()
        }

        var consumed: Int {
            lock.lock()
            defer { lock.unlock() }
            return total
        }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - `.pong` answers the pinging peer

    func testPongLandsOnTheControlChannelOfThePingingSubscriber() async {
        let firstControl = SendRecorder()
        let session = MuxChannelSession(
            channelID: 3,
            pty: unattachedPTY(),
            data: MuxSubChannel(channelID: 3, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 3, channel: .control) { _, frame in firstControl.record(frame) },
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.startRelay()
        session.detach(onDetachedExit: { _ in })

        let secondControl = SendRecorder()
        let joinedControl = MuxSubChannel(channelID: 3, channel: .control) { _, frame in
            secondControl.record(frame)
        }
        XCTAssertTrue(session.rebindRelay(
            data: MuxSubChannel(channelID: 3, channel: .data) { _, _ in },
            control: joinedControl,
            onExit: nil,
        ))

        let stamp: UInt64 = 1_749_700_000_123
        await joinedControl.deliver(payload: WireMessage.ping(timestampMS: stamp).encode())

        await waitUntil { secondControl.all.contains(.pong(timestampMS: stamp)) }
        XCTAssertTrue(
            secondControl.all.contains(.pong(timestampMS: stamp)),
            "the pong echoes the pinging peer's stamp back on the channel the ping arrived on",
        )
        XCTAssertFalse(
            firstControl.all.contains(.pong(timestampMS: stamp)),
            "and nowhere else — a foreign stamp folded by another client's recordPong is a bogus RTT",
        )

        session.pty.completeExitForTesting(code: 0)
        session.shutdownDetached()
    }

    // MARK: - `.metadataResponse` answers the requesting peer

    func testMetadataResponseGoesOnlyToTheRequestingSubscriber() async {
        let firstControl = SendRecorder()
        let session = MuxChannelSession(
            channelID: 5,
            pty: unattachedPTY(),
            data: MuxSubChannel(channelID: 5, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 5, channel: .control) { _, frame in firstControl.record(frame) },
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.startRelay()
        session.detach(onDetachedExit: { _ in })

        let secondControl = SendRecorder()
        let joinedControl = MuxSubChannel(channelID: 5, channel: .control) { _, frame in
            secondControl.record(frame)
        }
        XCTAssertTrue(session.rebindRelay(
            data: MuxSubChannel(channelID: 5, channel: .data) { _, _ in },
            control: joinedControl,
            onExit: nil,
        ))

        // An unknown verb: the pure builder answers with the standard error status and never
        // forks a probe subprocess (the always-replies contract, no syscalls).
        let requestID: UInt32 = 7
        await joinedControl.deliver(
            payload: WireMessage.metadataRequest(requestID: requestID, verb: 0xEE, payload: Data()).encode(),
        )

        await waitUntil {
            secondControl.all.contains { message in
                if case let .metadataResponse(id, _, _) = message { return id == requestID }
                return false
            }
        }
        XCTAssertTrue(
            secondControl.all.contains { message in
                if case let .metadataResponse(id, _, _) = message { return id == requestID }
                return false
            },
            "the metadata reply lands on the control channel the request arrived on",
        )
        XCTAssertFalse(
            firstControl.all.contains { message in
                if case let .metadataResponse(id, _, _) = message { return id == requestID }
                return false
            },
            "requestID counters are PER CLIENT and start at 1 — a broadcast reply pops a foreign "
                + "waiter and hands it somebody else's payload",
        )

        session.pty.completeExitForTesting(code: 0)
        session.shutdownDetached()
    }

    // MARK: - Credit returns to the channel the input arrived on

    /// Each ``MuxSubChannel`` owns its own ``ReceiveWindowAccountant`` and grants credit at
    /// CONSUMPTION. Crediting anything but the originating channel parks the real sender after one
    /// window with no event that can ever wake it — a client whose typing dies mid-paste.
    func testInputCreditIsGrantedOnTheOriginatingDataChannel() async {
        let firstCredit = CreditRecorder()
        let firstData = MuxSubChannel(
            channelID: 6, channel: .data,
            consumedSink: { bytes in firstCredit.add(bytes) },
            muxSend: { _, _ in },
        )
        let session = MuxChannelSession(
            channelID: 6,
            pty: unattachedPTY(),
            data: firstData,
            control: MuxSubChannel(channelID: 6, channel: .control) { _, _ in },
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.ptyWriteOverrideForTesting = { _ in }
        session.startRelay()

        let firstFrame = WireMessage.input(Data("abc".utf8))
        await firstData.deliver(payload: firstFrame.encode())
        await waitUntil { firstCredit.consumed == firstFrame.wireByteCount }
        XCTAssertEqual(
            firstCredit.consumed, firstFrame.wireByteCount,
            "the opening subscriber's own DATA channel is credited for what it delivered",
        )

        session.detach(onDetachedExit: { _ in })
        let secondCredit = CreditRecorder()
        let joinedData = MuxSubChannel(
            channelID: 6, channel: .data,
            consumedSink: { bytes in secondCredit.add(bytes) },
            muxSend: { _, _ in },
        )
        XCTAssertTrue(session.rebindRelay(
            data: joinedData,
            control: MuxSubChannel(channelID: 6, channel: .control) { _, _ in },
            onExit: nil,
        ))

        let secondFrame = WireMessage.input(Data("defgh".utf8))
        await joinedData.deliver(payload: secondFrame.encode())
        await waitUntil { secondCredit.consumed == secondFrame.wireByteCount }
        XCTAssertEqual(
            secondCredit.consumed, secondFrame.wireByteCount,
            "the joining subscriber's DATA channel is credited for ITS bytes",
        )
        XCTAssertEqual(
            firstCredit.consumed, firstFrame.wireByteCount,
            "and the retired channel receives no further credit — a window grant on the wrong "
                + "channel never wakes the parked sender",
        )

        session.pty.completeExitForTesting(code: 0)
        session.shutdownDetached()
    }

    // MARK: - A retired subscriber's tail cannot speak for the session

    /// The input relay ends by declaring the SESSION offline. That verdict has to be recomputed
    /// from the subscriber set, not asserted by the departing loop: a stale tail — an input task
    /// cancelled by `detach()` but still parked in a blocking PTY write when the client returns —
    /// otherwise flips the freshly reattached session offline and engages the 64 MiB replay gate
    /// that PAUSES the PTY drain for a client that is right there.
    func testAStaleInputTailCannotMarkAReattachedSessionOffline() async {
        let firstData = MuxSubChannel(channelID: 8, channel: .data) { _, _ in }
        let session = MuxChannelSession(
            channelID: 8,
            pty: unattachedPTY(),
            data: firstData,
            control: MuxSubChannel(channelID: 8, channel: .control) { _, _ in },
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        // The write parks the input task INSIDE its loop body, so its tail is guaranteed to run
        // after the reattach below rather than racing it.
        session.ptyWriteOverrideForTesting = { _ in Thread.sleep(forTimeInterval: 0.4) }
        session.startRelay()
        await firstData.deliver(payload: WireMessage.input(Data("parked".utf8)).encode())
        try? await Task.sleep(for: .milliseconds(60)) // the write block is now running

        session.detach(onDetachedExit: { _ in })
        XCTAssertTrue(session.rebindRelay(
            data: MuxSubChannel(channelID: 8, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 8, channel: .control) { _, _ in },
            onExit: nil,
        ))
        XCTAssertTrue(session.isClientOnlineForTesting, "precondition: the reattach marked the pane online")

        // Let the parked write finish so the retired input loop reaches its tail.
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(
            session.isClientOnlineForTesting,
            "the reattached session must stay ONLINE — the online truth is a recompute over the "
                + "subscriber set, not a verdict the departing loop gets to assert",
        )

        session.pty.completeExitForTesting(code: 0)
        session.shutdownDetached()
    }
}
