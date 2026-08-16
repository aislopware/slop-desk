import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// Two clients hold one PTY, and a laggard is evicted rather than indulged.
///
/// Fan-out and retention+eviction are one change, deliberately: fan-out alone makes the product
/// WORSE, because a single sleeping phone would pin the replay buffer and the out-FIFO for every
/// other client on the pane. So every assertion here comes in pairs — what the second subscriber
/// GETS, and what it is not allowed to COST.
///
/// Headless: unspawned ``PTYProcess``, no read loop, no `SCStream`/VideoToolbox. The producer side
/// is driven through the same `…ForTesting` seams the drain-merge and subscriber-set suites use.
final class MuxChannelSessionFanOutTests: XCTestCase {
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

        var exitCodes: [Int32] {
            lock.lock()
            defer { lock.unlock() }
            return messages.compactMap { if case let .exit(code) = $0 { code } else { nil } }
        }
    }

    private func makeSession(data: MuxSubChannel, control: MuxSubChannel) -> MuxChannelSession {
        MuxChannelSession(channelID: 1, pty: unattachedPTY(), data: data, control: control)
    }

    /// `window: nil` on a DATA channel means the production initial window; a SMALL value drives
    /// the credit-park path without pushing a whole window of bytes.
    private func makeChannel(
        _ recorder: SendRecorder,
        kind: Channel,
        window: Int? = nil,
    ) -> MuxSubChannel {
        MuxSubChannel(
            channelID: 1,
            channel: kind,
            sendWindowBytes: kind == .control ? nil : (window ?? MuxFlowControl.initialWindowBytes),
        ) { _, frame in
            recorder.record(frame)
        }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A live one-subscriber session with its relay running and a generous gate.
    private func makeLiveSession(primary: SendRecorder, primaryControl: SendRecorder) -> MuxChannelSession {
        let session = makeSession(
            data: makeChannel(primary, kind: .data),
            control: makeChannel(primaryControl, kind: .control),
        )
        session.installGateForTesting(PausableQueueGate(capacity: 8 * 1024 * 1024) { _ in })
        session.startRelay()
        return session
    }

    // MARK: - The second subscriber gets the same bytes

    /// The fan-out itself: a joiner enters a LIVE session's set, and everything the drain
    /// sequences afterwards reaches BOTH data channels.
    func testASecondSubscriberReceivesTheSamePTYBytes() async {
        let a = SendRecorder()
        let aControl = SendRecorder()
        let session = makeLiveSession(primary: a, primaryControl: aControl)
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        session.enqueueChunkForTesting(bytes: Data("before-join\n".utf8))
        await waitUntil { a.outputBytes.contains(Data("before-join\n".utf8)) }
        XCTAssertFalse(
            session.isFannedOutForTesting,
            "precondition: one member means the drain is on its inline single-send fast path",
        )

        let b = SendRecorder()
        let bControl = SendRecorder()
        let joined = await session.joinSubscriber(
            data: makeChannel(b, kind: .data),
            control: makeChannel(bControl, kind: .control),
            sizePassive: false,
        )
        XCTAssertNotNil(joined, "a live pane must accept a join")
        XCTAssertEqual(session.subscriberCountForTesting, 2)
        XCTAssertTrue(session.isFannedOutForTesting, "a second member switches the drain to outboxes")

        session.enqueueChunkForTesting(bytes: Data("after-join\n".utf8))
        await waitUntil {
            a.outputBytes.contains(Data("after-join\n".utf8))
                && b.outputBytes.contains(Data("after-join\n".utf8))
        }
        XCTAssertTrue(
            a.outputBytes.contains(Data("after-join\n".utf8)),
            "the incumbent keeps receiving: got \(a.outputBytes.count) bytes",
        )
        XCTAssertTrue(
            b.outputBytes.contains(Data("after-join\n".utf8)),
            "the SECOND subscriber receives the same PTY bytes: got \(b.outputBytes.count) bytes",
        )
    }

    /// The join boundary: the state transfer and the live stream must MEET. Every byte the pane
    /// produced reaches the joiner EXACTLY once — not twice (the snapshot re-shipping what the
    /// drain then delivers) and not zero times (frames sequenced while the screen was rendering,
    /// which go only to the incumbent and sit below the seqs the joiner starts from).
    ///
    /// The render runs OUTSIDE the drain-ordering lock so it cannot stall the incumbent, which is
    /// precisely what opens the window this pins closed.
    func testTheJoinBoundaryDeliversEveryByteExactlyOnce() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        let history = "HISTORY_MARKER\n"
        session.enqueueChunkForTesting(bytes: Data(history.utf8))
        try? await Task.sleep(for: .milliseconds(20))

        let b = SendRecorder()
        let joined = await session.joinSubscriber(
            data: makeChannel(b, kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        XCTAssertNotNil(joined)

        let live = "LIVE_MARKER\n"
        session.enqueueChunkForTesting(bytes: Data(live.utf8))
        await waitUntil { (String(bytes: b.outputBytes, encoding: .utf8) ?? "").contains("LIVE_MARKER") }

        let received = String(bytes: b.outputBytes, encoding: .utf8) ?? ""
        XCTAssertEqual(
            received.components(separatedBy: "HISTORY_MARKER").count - 1, 1,
            "the pre-join byte arrives once, via the state transfer: \(received.suffix(400))",
        )
        XCTAssertEqual(
            received.components(separatedBy: "LIVE_MARKER").count - 1, 1,
            "and the post-join byte arrives once, via the live drain: \(received.suffix(400))",
        )
        // Seqs the joiner receives must ascend without repeating — a duplicate seq is what the
        // client's `highestSeqFed` dedup would silently swallow, hiding the fault.
        let seqs = b.all.compactMap { if case let .output(seq, _) = $0 { seq } else { nil } }
        XCTAssertEqual(seqs, seqs.sorted(), "the joiner's stream is monotonic")
        XCTAssertEqual(Set(seqs).count, seqs.count, "and carries no seq twice")
    }

    /// Pane-wide control facts fan to everybody; the joiner also gets its JOIN-scoped re-asserts.
    func testControlFactsFanToEverySubscriber() async {
        let a = SendRecorder()
        let aControl = SendRecorder()
        let session = makeLiveSession(primary: a, primaryControl: aControl)
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        let b = SendRecorder()
        let bControl = SendRecorder()
        _ = await session.joinSubscriber(
            data: makeChannel(b, kind: .data),
            control: makeChannel(bControl, kind: .control),
            sizePassive: false,
        )
        session.enqueueChunkForTesting(bytes: Data("x".utf8), control: [.title("shared")])
        await waitUntil {
            aControl.all.contains(.title("shared")) && bControl.all.contains(.title("shared"))
        }
        XCTAssertTrue(aControl.all.contains(.title("shared")), "the incumbent is told")
        XCTAssertTrue(bControl.all.contains(.title("shared")), "and so is the joiner")
    }

    // MARK: - Retention is the MIN, not the newest ack

    /// The whole point of a min-fold: the FAST client's ack must not release bytes the slow one
    /// has not received. `ReplayBuffer.ackedSeq` is also the ring/tail split point, so an
    /// over-advanced watermark does not merely drop bytes — it files still-un-acked live tail into
    /// the ACKED ring, where line-aligned scrollback eviction is free to discard it, and the
    /// client's forward-jump tolerance then accepts the hole with no error and no log.
    func testTheFastSubscribersAckDoesNotReleaseTheLaggardsBytes() async {
        let a = SendRecorder()
        let session = makeLiveSession(primary: a, primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        let joined = await session.joinSubscriber(
            data: makeChannel(SendRecorder(), kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        guard let laggard = joined else {
            XCTFail("join must succeed")
            return
        }

        // Three frames after the join, so both members are behind all of them.
        session.ackForTesting(upTo: 0, from: laggard) // the joiner starts at the head; reset it
        let s1 = session.appendForTesting(Data(repeating: 0x41, count: 100))
        let s2 = session.appendForTesting(Data(repeating: 0x42, count: 100))
        let s3 = session.appendForTesting(Data(repeating: 0x43, count: 100))
        XCTAssertEqual(session.retainedBytesForTesting, 300, "precondition: nothing acked yet")

        // The FAST member confirms everything.
        session.ackForTesting(upTo: s3, from: MuxChannelSession.primarySubscriberID)
        XCTAssertEqual(
            session.ackedSeqForTesting, 0,
            "retention releases to the MIN, and the laggard has confirmed nothing",
        )
        XCTAssertEqual(
            session.retainedBytesForTesting, 300,
            "not one byte the laggard still needs may be released by somebody else's progress",
        )

        // The laggard catches up part-way: the floor moves to ITS cursor, not the fast one's.
        session.ackForTesting(upTo: s1, from: laggard)
        XCTAssertEqual(session.ackedSeqForTesting, s1)
        XCTAssertEqual(session.retainedBytesForTesting, 200)

        // And all the way: now the whole tail is releasable.
        session.ackForTesting(upTo: s3, from: laggard)
        XCTAssertEqual(session.ackedSeqForTesting, s3)
        XCTAssertEqual(session.retainedBytesForTesting, 0)
        XCTAssertGreaterThan(s2, s1, "sanity: seqs ascend")
    }

    /// A member LEAVING must release what it was pinning. A departed cursor left in the fold would
    /// hold the buffer at a floor nobody is waiting for, forever.
    func testRemovingALaggardReleasesTheBytesItWasPinning() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        let joined = await session.joinSubscriber(
            data: makeChannel(SendRecorder(), kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        guard let laggard = joined else {
            XCTFail("join must succeed")
            return
        }
        session.ackForTesting(upTo: 0, from: laggard)

        let head = session.appendForTesting(Data(repeating: 0x41, count: 500))
        session.ackForTesting(upTo: head, from: MuxChannelSession.primarySubscriberID)
        XCTAssertEqual(session.retainedBytesForTesting, 500, "precondition: the laggard pins the tail")

        let emptied = session.removeSubscriber(laggard)
        XCTAssertFalse(emptied, "one of two leaving does not empty the set")
        XCTAssertEqual(
            session.retainedBytesForTesting, 0,
            "the departed member's cursor is out of the fold, so the tail is released",
        )
    }

    // MARK: - A laggard is evicted, from the PRODUCER side too

    /// A client that has stopped acking never calls `acknowledge`, so a consumer-side-only check
    /// would never fire on the exact member it exists to remove. The producer path
    /// (`sequenceAndFanOut` → append) has to run it too.
    func testALaggardIsEvictedFromTheProducerSideWhenItNeverAcks() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        let evicted = EvictionBox()
        session.onEvictSubscriber = { id in evicted.append(id) }

        let joined = await session.joinSubscriber(
            data: makeChannel(SendRecorder(), kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        guard let laggard = joined else {
            XCTFail("join must succeed")
            return
        }
        session.ackForTesting(upTo: 0, from: laggard)

        // The healthy member keeps up; the laggard never acks. NOTHING calls `acknowledge` for it,
        // so only the append path can notice.
        let payload = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<40 {
            let seq = session.appendForTesting(payload)
            session.ackForTesting(upTo: seq, from: MuxChannelSession.primarySubscriberID)
            if !evicted.all.isEmpty { break }
        }
        await waitUntil { !evicted.all.isEmpty }
        XCTAssertEqual(
            evicted.all, [laggard],
            "the member more than SLOPDESK_SUB_LAG_BYTES behind is evicted — and only it",
        )
    }

    /// The survivor rule: eviction can never take a pane to zero members. If EVERY member is
    /// behind the threshold then nobody is consuming, which is the ReplayBuffer's offline gate's
    /// job, not eviction's.
    func testTheHealthIESTSubscriberIsNeverEvicted() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        let evicted = EvictionBox()
        session.onEvictSubscriber = { id in evicted.append(id) }

        let joined = await session.joinSubscriber(
            data: makeChannel(SendRecorder(), kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        guard let laggard = joined else {
            XCTFail("join must succeed")
            return
        }
        session.ackForTesting(upTo: 0, from: laggard)

        // NEITHER member acks.
        let payload = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<40 { session.appendForTesting(payload) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(
            evicted.all.isEmpty,
            "with nobody consuming the offline gate applies, not eviction: got \(evicted.all)",
        )
        XCTAssertEqual(session.subscriberCountForTesting, 2)
        XCTAssertNotEqual(laggard, MuxChannelSession.primarySubscriberID)
    }

    /// The flag-OFF claim, made checkable: a LONE subscriber is never evicted however far behind
    /// it falls. Its backpressure is the 64 MiB offline gate / 256 MiB cap, exactly as it has
    /// always been — evicting it would turn a slow link into a dropped session.
    func testASoleSubscriberIsNeverEvictedHoweverFarBehind() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        let evicted = EvictionBox()
        session.onEvictSubscriber = { id in evicted.append(id) }

        let payload = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<40 { session.appendForTesting(payload) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(evicted.all.isEmpty, "the only member is never the laggard: got \(evicted.all)")
        XCTAssertFalse(
            session.isFannedOutForTesting,
            "and the drain never left its inline fast path — the shipping path is untouched",
        )
    }

    /// Eviction must not deadlock against the condition it breaks: the laggard is BY DEFINITION
    /// parked inside `MuxSubChannel.send` on an exhausted credit window. Retiring it cancels its
    /// sender, and the credit park is cancellation-aware, so the parked task unwinds — without the
    /// session ever calling into the channel it is blocked on.
    func testEvictionWakesASenderParkedOnAnExhaustedCreditWindow() async {
        let a = SendRecorder()
        let session = makeLiveSession(primary: a, primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        // The joiner's DATA channel has a TINY send window and nothing ever grants more credit, so
        // its sender parks on the first oversized frame and never returns.
        let b = SendRecorder()
        let joined = await session.joinSubscriber(
            data: makeChannel(b, kind: .data, window: 64),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        guard let stuck = joined else {
            XCTFail("join must succeed")
            return
        }

        session.enqueueChunkForTesting(bytes: Data(repeating: 0x41, count: 16 * 1024))
        session.enqueueChunkForTesting(bytes: Data(repeating: 0x42, count: 16 * 1024))
        // The HEALTHY member is not held up by the parked one: that is the outbox's whole purpose.
        await waitUntil { a.outputBytes.count >= 32 * 1024 }
        XCTAssertGreaterThanOrEqual(
            a.outputBytes.count, 32 * 1024,
            "a parked subscriber must not give itself head-of-line over a healthy one",
        )

        // Evicting the parked member returns promptly — no deadlock against its own park.
        let done = EvictionBox()
        let task = Task {
            _ = session.removeSubscriber(stuck)
            done.append(stuck)
        }
        await waitUntil { !done.all.isEmpty }
        XCTAssertEqual(done.all, [stuck], "retiring a credit-parked member must not block")
        XCTAssertEqual(session.subscriberCountForTesting, 1)
        _ = await task.value

        // And the survivor keeps flowing afterwards.
        session.enqueueChunkForTesting(bytes: Data("still-alive\n".utf8))
        await waitUntil { a.outputBytes.contains(Data("still-alive\n".utf8)) }
        XCTAssertTrue(a.outputBytes.contains(Data("still-alive\n".utf8)))
    }

    // MARK: - Leaving is refcounted

    /// One of two leaving must NOT engage the offline gate. `setClientOnline(false)` pauses the
    /// PTY drain, so the survivor's pane would go dead-quiet while the shell keeps producing — and
    /// the wake continuation is nil'd on detach, so not even a later chunk could re-wake it.
    func testRemovingOneOfTwoSubscribersDoesNotPauseTheDrain() async {
        let a = SendRecorder()
        let session = makeLiveSession(primary: a, primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        let b = SendRecorder()
        let joined = await session.joinSubscriber(
            data: makeChannel(b, kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        guard let leaver = joined else {
            XCTFail("join must succeed")
            return
        }

        let emptied = session.removeSubscriber(leaver)
        XCTAssertFalse(emptied, "the set is not empty — the incumbent is still here")
        XCTAssertTrue(
            session.isClientOnlineForTesting,
            "somebody still holds the pane, so the offline gate must stay clear",
        )

        session.enqueueChunkForTesting(bytes: Data("after-leave\n".utf8))
        await waitUntil { a.outputBytes.contains(Data("after-leave\n".utf8)) }
        XCTAssertTrue(
            a.outputBytes.contains(Data("after-leave\n".utf8)),
            "the survivor keeps receiving live output",
        )
        let bBytes = b.outputBytes.count
        XCTAssertFalse(
            b.outputBytes.dropFirst(bBytes).contains(Data("after-leave\n".utf8)),
            "the departed member's channel goes quiet",
        )
    }

    /// The LAST member leaving does empty the set, which is what the session-wide teardown belongs
    /// to. The caller (HostServer) parks the session then, and only then.
    func testTheLastSubscriberLeavingEmptiesTheSet() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        let joined = await session.joinSubscriber(
            data: makeChannel(SendRecorder(), kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        guard let second = joined else {
            XCTFail("join must succeed")
            return
        }
        XCTAssertFalse(session.removeSubscriber(second))
        XCTAssertTrue(
            session.removeSubscriber(MuxChannelSession.primarySubscriberID),
            "the LAST member leaving is what empties the set",
        )
        XCTAssertEqual(session.subscriberCountForTesting, 0)
        XCTAssertFalse(session.isClientOnlineForTesting, "and only now does the pane read offline")
    }

    // MARK: - `.exit` reaches everybody

    /// Signalling the exit latch after the FIRST send would release the exit task → `onExit` →
    /// `shutdown()` → `outputTask.cancel()`, and members 2..N would never receive the exit code:
    /// their panes hang showing a shell that is already dead.
    func testExitReachesEverySubscriber() async {
        let a = SendRecorder()
        let session = makeLiveSession(primary: a, primaryControl: SendRecorder())
        defer { session.shutdownDetached() }

        let b = SendRecorder()
        _ = await session.joinSubscriber(
            data: makeChannel(b, kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        XCTAssertEqual(session.subscriberCountForTesting, 2)

        session.enqueueExitForTesting(code: 7)
        await waitUntil { !a.exitCodes.isEmpty && !b.exitCodes.isEmpty }
        XCTAssertEqual(a.exitCodes, [7], "the incumbent gets the exit code")
        XCTAssertEqual(b.exitCodes, [7], "and so does the second subscriber")
        await waitUntil { session.isExitSentForTesting() }
        XCTAssertTrue(
            session.isExitSentForTesting(),
            "the latch releases only once every reachable member has been told",
        )
    }

    // MARK: - The fan-out shape does not outlive the set that caused it

    /// A pane that was fanned out, then EMPTIED, then reattached is a one-member pane again — and
    /// its drain has to be back on the inline send.
    ///
    /// `fanoutActive` survives a member merely leaving (flipping modes under a surviving sender
    /// would put two writers on one data channel), but `rebindRelay` builds only the returning
    /// member's CONTROL sender — the two `startDataSender` sites are both inside the JOIN path. A
    /// drain still in its fan-out shape would therefore hand every frame to an outbox with a nil
    /// wake: the client sees the caller's `replayTail` state transfer and then silence, `.exit`
    /// included, while `dequeueOutput` keeps the queue gate flowing so the PTY never backpressures.
    func testAReattachAfterAFanOutGoesBackToTheInlineSend() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        let joined = await session.joinSubscriber(
            data: makeChannel(SendRecorder(), kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        XCTAssertNotNil(joined, "precondition: the pane really did fan out")
        XCTAssertTrue(session.isFannedOutForTesting)

        // Both links drop: the set empties and the session parks, as `handleLinkDown` leaves it.
        session.detach(onDetachedExit: { _ in })
        XCTAssertEqual(session.subscriberCountForTesting, 0, "precondition: the set emptied")

        let back = SendRecorder()
        XCTAssertTrue(session.rebindRelay(
            data: makeChannel(back, kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            onExit: nil,
        ))
        XCTAssertFalse(
            session.isFannedOutForTesting,
            "an emptied set leaves no sender mid-outbox, so the returning client is one member again",
        )

        session.enqueueChunkForTesting(bytes: Data("AFTER_REATTACH\n".utf8))
        await waitUntil { back.outputBytes.contains(Data("AFTER_REATTACH\n".utf8)) }
        XCTAssertTrue(
            back.outputBytes.contains(Data("AFTER_REATTACH\n".utf8)),
            "the reattached client receives live output; got \(back.outputBytes.count) bytes",
        )

        session.enqueueExitForTesting(code: 3)
        await waitUntil { back.exitCodes == [3] }
        XCTAssertEqual(back.exitCodes, [3], "and the shell's exit code, which rides the same flag")
        session.shutdownDetached()
    }

    /// Frames the drain fans out WHILE a joiner's state transfer is on the wire must reach it
    /// without waiting for the next PTY byte.
    ///
    /// `admitJoiner` enters the member before its sender exists, so those frames land in an outbox
    /// whose `dataWake` is still nil and whose producer-side yields go nowhere. `startDataSender`
    /// then installs the wake and parks on an empty `bufferingNewest(1)` stream. A pane that goes
    /// idle right after a join — a finished build, a returned prompt — would leave the joiner on the
    /// pre-join screen until something unrelated happened to produce output.
    func testTheJoinersSenderShipsWhatArrivedBeforeItExisted() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }

        let marker = Data("DURING_TRANSFER\n".utf8)
        session.onJoinerAdmittedForTesting = { [weak session] in
            guard let session else { return }
            let before = session.retainedBytesForTesting
            session.enqueueChunkForTesting(bytes: marker)
            // Wait for the drain to have SEQUENCED it: the append and the hand-off to every
            // member's outbox happen in one critical section, so a grown retention total means the
            // frame is already sitting in the joiner's queue with no wake. Without this the test
            // could pass for the wrong reason — a later enqueue carrying a wake of its own.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline, session.retainedBytesForTesting == before {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        let b = SendRecorder()
        let joined = await session.joinSubscriber(
            data: makeChannel(b, kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        XCTAssertNotNil(joined)

        // NOTHING is enqueued after the join, deliberately: the only wake that can ship this frame
        // is the one `startDataSender` gives itself.
        await waitUntil { b.outputBytes.contains(marker) }
        XCTAssertTrue(
            b.outputBytes.contains(marker),
            "the joiner's own sender flushes what accumulated before it existed; got "
                + "\(b.outputBytes.count) bytes",
        )
    }

    // MARK: - A departed member's late ack

    /// A retired member's control relay can still deliver one buffered `.ack`: `Task.cancel()` does
    /// not unwind an iteration already in flight. Honouring that cursor would release the tail of a
    /// laggard that is STILL HERE — its later cold reattach then composes from a truncated history,
    /// and `evictLaggingSubscribers` under-reports its lag because the retained bytes collapsed.
    func testALateAckFromADepartedMemberDoesNotReleaseTheSurvivorsTail() async {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        let joined = await session.joinSubscriber(
            data: makeChannel(SendRecorder(), kind: .data),
            control: makeChannel(SendRecorder(), kind: .control),
            sizePassive: false,
        )
        guard let fast = joined else {
            XCTFail("join must succeed")
            return
        }
        session.ackForTesting(upTo: 0, from: fast)

        let s1 = session.appendForTesting(Data(repeating: 0x41, count: 100))
        let s2 = session.appendForTesting(Data(repeating: 0x42, count: 100))
        session.ackForTesting(upTo: s1, from: MuxChannelSession.primarySubscriberID)
        session.ackForTesting(upTo: s2, from: fast)
        XCTAssertEqual(session.ackedSeqForTesting, s1, "precondition: the survivor's cursor is the floor")

        XCTAssertFalse(session.removeSubscriber(fast), "one of two leaving does not empty the set")
        session.ackForTesting(upTo: s2, from: fast) // the buffered ack its cancelled relay still had

        XCTAssertEqual(
            session.ackedSeqForTesting, s1,
            "a ghost's cursor may not release bytes the member that REMAINS has not confirmed",
        )
        XCTAssertEqual(session.retainedBytesForTesting, 100)
    }

    /// The other half: with the set EMPTY there is genuinely no laggard left to hold the buffer for,
    /// so an ack still releases. This is the ack test seam's own path, and dropping it would leave a
    /// parked session pinning its whole tail forever.
    func testAnAckOnAnEmptySetStillReleases() {
        let session = makeLiveSession(primary: SendRecorder(), primaryControl: SendRecorder())
        defer { session.pty.completeExitForTesting(code: 0)
            session.shutdownDetached()
        }
        let seq = session.appendForTesting(Data(repeating: 0x41, count: 100))
        XCTAssertTrue(session.removeSubscriber(MuxChannelSession.primarySubscriberID))
        session.ackForTesting(upTo: seq)
        XCTAssertEqual(session.ackedSeqForTesting, seq)
        XCTAssertEqual(session.retainedBytesForTesting, 0)
    }

    /// Thread-safe collector for eviction ids (the seam fires from a detached task).
    private final class EvictionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [MuxSubscriberID] = []
        func append(_ id: MuxSubscriberID) {
            lock.lock()
            ids.append(id)
            lock.unlock()
        }

        var all: [MuxSubscriberID] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }
}
