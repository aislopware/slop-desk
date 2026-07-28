import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// A `channelClass == 2` subscriber READS the pane and never writes to it (docs/45 §8.4).
///
/// Read-only is a property of the SUBSCRIBER, not of the session: the same `MuxChannelSession` fans
/// bytes to a writing member and an observing one at the same time, and the orchestrator's raw
/// injection path (`writeRawForControl`) keeps writing regardless. A session-level flag would gag
/// all three.
///
/// Headless: unspawned ``PTYProcess`` (masterFD −1, no reaper thread), input intercepted at the
/// serial writer's test seam, so nothing here forks a shell — the hang-safety rule.
final class MuxChannelSessionObserverTests: XCTestCase {
    // MARK: - Rig

    /// Records what the PTY writer was asked to write, from the session's serial `inputQueue`.
    private final class WriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []

        func record(_ bytes: Data) {
            lock.lock()
            chunks.append(bytes)
            lock.unlock()
        }

        var written: Data {
            lock.lock()
            defer { lock.unlock() }
            return chunks.reduce(into: Data()) { $0.append($1) }
        }
    }

    /// Sums the bytes a sub-channel's consumer reports CONSUMED — the exact signal that re-grants
    /// the peer's send window.
    private final class CreditRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0

        func note(_ bytes: Int) {
            lock.lock()
            total += bytes
            lock.unlock()
        }

        var credited: Int {
            lock.lock()
            defer { lock.unlock() }
            return total
        }
    }

    private var sessions: [MuxChannelSession] = []

    override func tearDown() {
        for session in sessions { session.shutdownDetached() }
        sessions = []
    }

    /// - Parameter relay: whether to `startRelay()`. The AGENT tests pass `false`: the relay arms a
    ///   ~1 Hz foreground poll, and on this unspawned PTY that poll folds "no process here" through
    ///   the presence heuristic and can reset the detector's status out from under an assertion —
    ///   a wall-clock race that only shows up under a loaded full-suite run. The primary subscriber
    ///   is seeded at `init`, so a join still works without it.
    private func makeSession(
        agentDetectEnabled: Bool = false,
        relay: Bool = true,
    ) -> MuxChannelSession {
        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — no fork, no reaper
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            agentDetectEnabled: agentDetectEnabled,
        )
        session.installGateForTesting(PausableQueueGate(capacity: 8 * 1024 * 1024) { _ in })
        if relay { session.startRelay() }
        sessions.append(session)
        return session
    }

    private func makeDataChannel(credit: CreditRecorder? = nil) -> MuxSubChannel {
        MuxSubChannel(
            channelID: 1,
            channel: .data,
            sendWindowBytes: MuxFlowControl.initialWindowBytes,
            consumedSink: { bytes in credit?.note(bytes) },
        ) { _, _ in }
    }

    private func makeControlChannel() -> MuxSubChannel {
        MuxSubChannel(channelID: 1, channel: .control, sendWindowBytes: nil) { _, _ in }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Input is dropped, and STILL credited

    /// The trap that would only show up on hardware: credit is granted at CONSUMPTION
    /// (``MuxSubChannel/noteConsumed(_:)``), so a frame that is dropped WITHOUT being credited never
    /// returns the window. The observer's sender parks after exactly one window and the channel dies
    /// silently — no error, no log, nothing to grep for.
    ///
    /// So the assertion is a pair: the bytes never reach the PTY, and every one of them is credited.
    /// More than a full window is delivered, so a build that drops-without-crediting cannot pass by
    /// accident.
    func testAnObserversInputIsDroppedButStillCredited() async {
        let writes = WriteRecorder()
        let session = makeSession()
        session.ptyWriteOverrideForTesting = { writes.record($0) }

        let credit = CreditRecorder()
        let observerData = makeDataChannel(credit: credit)
        let joined = await session.joinSubscriber(
            data: observerData,
            control: makeControlChannel(),
            channelClass: .paneObserver,
            sizePassive: false,
        )
        XCTAssertNotNil(joined, "an observer joins a live pane")

        // One 8 KiB payload per frame, enough frames to overrun the initial window several times
        // over — the exact shape that wedges when a drop skips the credit.
        let payload = Data(repeating: 0x61, count: 8 * 1024)
        let frames = (MuxFlowControl.initialWindowBytes / payload.count) + 4
        var expected = 0
        for _ in 0..<frames {
            let message = WireMessage.input(payload)
            expected += message.wireByteCount
            await observerData.deliver(payload: message.encode())
        }

        let expectedCredit = expected
        await waitUntil { credit.credited >= expectedCredit }
        XCTAssertEqual(
            credit.credited, expected,
            "every dropped frame is still credited — an uncredited drop parks the sender at one window",
        )
        XCTAssertGreaterThan(
            expected, MuxFlowControl.initialWindowBytes,
            "precondition: more than one window was delivered, so a wedge would be visible",
        )
        XCTAssertTrue(
            writes.written.isEmpty,
            "an observer writes nothing to the PTY",
        )
    }

    /// The control: an ORDINARY (`channelClass == 0`) member's input still reaches the PTY. A
    /// read-only enforcement that gagged everybody would pass the assertion above.
    func testAnOrdinaryMembersInputStillReachesThePTY() async {
        let writes = WriteRecorder()
        let session = makeSession()
        session.ptyWriteOverrideForTesting = { writes.record($0) }

        let peerData = makeDataChannel()
        let joined = await session.joinSubscriber(
            data: peerData,
            control: makeControlChannel(),
            sizePassive: false,
        )
        XCTAssertNotNil(joined)

        await peerData.deliver(payload: WireMessage.input(Data("ls\r".utf8)).encode())
        await waitUntil { writes.written == Data("ls\r".utf8) }
        XCTAssertEqual(writes.written, Data("ls\r".utf8), "a pane-class member writes through")
    }

    /// `writeRawForControl` is the orchestrator's `slopdesk-ctl` injection path, and it is NOT a
    /// subscriber at all. A session-level `isReadOnly` flag would gag it the moment an observer
    /// joined, silently breaking every scripted answer while somebody watched.
    func testTheControlSocketStillWritesWhileAnObserverWatches() async {
        let writes = WriteRecorder()
        let session = makeSession()
        session.ptyWriteOverrideForTesting = { writes.record($0) }

        let joined = await session.joinSubscriber(
            data: makeDataChannel(),
            control: makeControlChannel(),
            channelClass: .paneObserver,
            sizePassive: false,
        )
        XCTAssertNotNil(joined)

        session.writeRawForControl(Data("2\r".utf8))
        await waitUntil { writes.written == Data("2\r".utf8) }
        XCTAssertEqual(
            writes.written, Data("2\r".utf8),
            "the ctl path is not a subscriber and keeps writing",
        )
    }

    // MARK: - The blocked hand stays up

    /// `foldUserInput` is the Esc-cancel UNBLOCK edge: a keystroke into a `.needsPermission` pane
    /// demotes it to `.idle` because the human is handling the dialog. Firing it for an observer
    /// would let a read-only client's stray keystroke clear ANOTHER client's blocked latch — the
    /// supervision alert vanishes and nobody answers the prompt.
    func testAnObserverKeystrokeDoesNotUnblockABlockedAgent() async throws {
        let session = makeSession(agentDetectEnabled: true, relay: false)
        session.ptyWriteOverrideForTesting = { _ in }
        session.ingestAgentHookRecord(Data(
            #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash?"}"#
                .utf8,
        ))
        XCTAssertEqual(
            session.agentStatusForControl, .needsPermission,
            "precondition: the pane is blocked on a human",
        )

        let observerData = makeDataChannel()
        let joined = await session.joinSubscriber(
            data: observerData,
            control: makeControlChannel(),
            channelClass: .paneObserver,
            sizePassive: false,
        )
        XCTAssertNotNil(joined)

        await observerData.deliver(payload: WireMessage.input(Data([0x1B])).encode())
        // The absence of an effect cannot be awaited — give the detached relay a real window to run
        // the fold it must not run.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(
            session.agentStatusForControl, .needsPermission,
            "a read-only client cannot answer another client's dialog",
        )
    }

    /// The control again: an ordinary member's Esc DOES drop the hand. Without this the assertion
    /// above would pass on a build that broke the unblock edge outright.
    func testAnOrdinaryMembersKeystrokeStillUnblocks() async {
        let session = makeSession(agentDetectEnabled: true, relay: false)
        session.ptyWriteOverrideForTesting = { _ in }
        session.ingestAgentHookRecord(Data(
            #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash?"}"#
                .utf8,
        ))
        XCTAssertEqual(session.agentStatusForControl, .needsPermission)

        let peerData = makeDataChannel()
        let joined = await session.joinSubscriber(
            data: peerData,
            control: makeControlChannel(),
            sizePassive: false,
        )
        XCTAssertNotNil(joined)

        await peerData.deliver(payload: WireMessage.input(Data([0x1B])).encode())
        await waitUntil { session.agentStatusForControl == .idle }
        XCTAssertEqual(
            session.agentStatusForControl, .idle,
            "a writing client's Esc is the human handling the dialog",
        )
    }

    // MARK: - An observer never clamps the grid

    /// An observer holds no opinion about the PTY's size: it did not choose the grid and cannot be
    /// allowed to shrink somebody else's shell by having a small window. It is published as an
    /// attachment (it IS holding the pane) with `contributes: false`.
    func testAnObserverContributesNothingToTheSizeFold() async throws {
        let session = makeSession()

        // The incumbent's offer resolves the grid on its own (0→1 contributors: no settle).
        session.scheduleResize(cols: 120, rows: 40, px: 0, py: 0)
        await waitUntil { session.resolvedGridForWorkspace.cols == 120 }
        XCTAssertEqual(session.resolvedGridForWorkspace.cols, 120)
        XCTAssertEqual(session.resolvedGridForWorkspace.rows, 40)

        let observerData = makeDataChannel()
        let observerControl = makeControlChannel()
        let joined = await session.joinSubscriber(
            data: observerData,
            control: observerControl,
            channelClass: .paneObserver,
            sizePassive: false,
        )
        let observer = try XCTUnwrap(joined)

        // A phone-sized offer from the observer. A contributing member would clamp the pane to it.
        await observerControl.deliver(
            payload: WireMessage.resize(cols: 40, rows: 12, pxWidth: 0, pxHeight: 0).encode(),
        )
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            session.resolvedGridForWorkspace.cols, 120,
            "the observer's window never shrinks the pane",
        )
        XCTAssertEqual(session.resolvedGridForWorkspace.rows, 40)
        let attachment = session.resizeContributionsForWorkspace.first { $0.subscriber == observer }
        XCTAssertNotNil(attachment, "the observer is still published — it IS holding the pane")
        XCTAssertEqual(
            attachment?.contributes, false,
            "…but the roster says it does not vote, so the UI can name who does",
        )
    }

    /// Passivity an observer can never shed. A pane held only by SIZE-PASSIVE members is sized by
    /// them (an iPhone-only setup would otherwise run every shell at 80×24) — but that fallback must
    /// not reach an observer, whose whole contract is that it watches a grid it did not choose.
    func testAnObserverAloneOnAPaneStillDoesNotSizeIt() async throws {
        let session = makeSession()
        session.scheduleResize(cols: 120, rows: 40, px: 0, py: 0)
        await waitUntil { session.resolvedGridForWorkspace.cols == 120 }

        let observerControl = makeControlChannel()
        let joined = await session.joinSubscriber(
            data: makeDataChannel(),
            control: observerControl,
            channelClass: .paneObserver,
            sizePassive: false,
        )
        let observer = try XCTUnwrap(joined)
        await observerControl.deliver(
            payload: WireMessage.resize(cols: 40, rows: 12, pxWidth: 0, pxHeight: 0).encode(),
        )

        // The holder leaves. The observer is now the only contributor in the set.
        session.removeSubscriber(MuxChannelSession.primarySubscriberID)
        session.applyResolvedGrid()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            session.resolvedGridForWorkspace.cols, 120,
            "a pane left to an observer keeps its size — the spectator does not inherit the vote",
        )
        XCTAssertEqual(
            session.resizeContributionsForWorkspace.first { $0.subscriber == observer }?.contributes,
            false,
            "and the roster still says the observer does not vote",
        )
    }

    /// …nor does an observer alone on a pane retire an orchestrator's `slopdesk-ctl resize`.
    ///
    /// The override yields to "the next CONTRIBUTING client offer" (§8.3 rule 6), and the fallback
    /// that lets a lone size-passive PANE member contribute deliberately stops short of a spectator.
    /// The two rules have to agree on who counts, or watching a pane would quietly undo the size an
    /// orchestrator set on it.
    func testAnObserverAloneOnAPaneDoesNotRetireTheCtlOverride() async throws {
        let session = makeSession()
        let observerControl = makeControlChannel()
        let joined = await session.joinSubscriber(
            data: makeDataChannel(),
            control: observerControl,
            channelClass: .paneObserver,
            sizePassive: false,
        )
        _ = try XCTUnwrap(joined)
        session.removeSubscriber(MuxChannelSession.primarySubscriberID)

        session.resizeForControl(rows: 50, cols: 132)
        await waitUntil { session.resolvedGridForWorkspace.cols == 132 }
        XCTAssertEqual(session.resolvedGridForWorkspace.cols, 132, "precondition: the override applies")

        await observerControl.deliver(
            payload: WireMessage.resize(cols: 40, rows: 12, pxWidth: 0, pxHeight: 0).encode(),
        )
        try await Task.sleep(for: .milliseconds(200))
        session.applyResolvedGrid()

        XCTAssertEqual(
            session.resolvedGridForWorkspace.cols, 132,
            "a spectator's window is not an offer the orchestrator's size yields to",
        )
        XCTAssertEqual(session.resolvedGridForWorkspace.rows, 50)
    }
}
