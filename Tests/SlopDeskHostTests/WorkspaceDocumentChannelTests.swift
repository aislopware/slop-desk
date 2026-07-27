import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskHost

/// A `MessageChannel` that records what the host sent and can be made to fail on demand.
///
/// The workspace channel's send path is `MessageChannel.send` and NOTHING else — deliberately, since
/// `MuxChannelSession.enqueueControl` sheds new messages past 1024 queued and a shed snapshot would
/// pin a client at `stateNum 0` with no retry trigger. Driving that seam directly is therefore the
/// honest unit under test.
private final class RecordingChannel: MessageChannel, @unchecked Sendable {
    let channel: Channel = .control

    private let lock = NSLock()
    private var _sent: [WireMessage] = []
    private var _dead = false
    /// Held sends, for proving that an update arriving MID-SEND still lands.
    private var _gate: CheckedContinuation<Void, Never>?
    private var _gated = false

    var sent: [WireMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    var events: [Event] {
        sent.compactMap {
            guard case let .workspaceEvent(kind, epoch, base, new, payload) = $0 else { return nil }
            return Event(kind: kind, epoch: epoch, base: base, new: new, payload: payload)
        }
    }

    func events(kind: WorkspaceEventKind) -> [Event] {
        events.filter { $0.kind == kind.rawValue }
    }

    func kill() {
        lock.lock()
        _dead = true
        lock.unlock()
    }

    var inbound: AsyncThrowingStream<WireMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// Synchronous so the lock is never held across a suspension — `NSLock` is unavailable from an
    /// async context precisely to stop that.
    private func record(_ message: WireMessage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_dead else { return false }
        _sent.append(message)
        return true
    }

    func send(_ message: WireMessage) async throws {
        // A real send suspends. Yielding here keeps the coalescing path honest: an update that
        // arrives WHILE a frame is in flight must land, not be swallowed by the single buffered wake.
        await Task.yield()
        guard record(message) else { throw ChannelDead() }
    }
}

private struct ChannelDead: Error {}

/// One decoded type-37 frame, as the client would see it.
private struct Event {
    var kind: UInt8
    var epoch: UUID
    var base: Int64
    var new: Int64
    var payload: Data
}

/// Polls until `predicate` holds, failing the test if it never does.
///
/// Polling rather than an `XCTestExpectation` because the unit under test is a detached send task
/// with no completion callback — and a fixed sleep either flakes or wastes a second on every run.
private func expect(
    _ predicate: @Sendable () -> Bool,
    _ what: String = "condition",
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    if !predicate() { XCTFail("timed out waiting for \(what)", file: file, line: line) }
}

final class WorkspaceDocumentChannelTests: XCTestCase {
    private let paneA = UUID(uuidString: "5D05DE5C-0000-4000-8000-0000000000A1")!
    private let paneB = UUID(uuidString: "5D05DE5C-0000-4000-8000-0000000000B2")!

    private func subscribe(clientKind: UInt8 = 0, label: String = "test") -> WorkspaceSubscribe {
        WorkspaceSubscribe(clientInstanceID: UUID(), clientKind: clientKind, label: label)
    }

    private func makeSession(
        _ channel: RecordingChannel,
        _ request: WorkspaceSubscribe? = nil,
    ) -> WorkspaceChannelSession {
        WorkspaceChannelSession(channel: channel, subscribe: request ?? subscribe())
    }

    // MARK: Snapshot / diff / ack

    func testFirstDeliveryIsASelfContainedSnapshot() async throws {
        let channel = RecordingChannel()
        let document = HostWorkspaceDocument(onLog: nil)
        await document.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "main.go - NVIM"))
        let session = makeSession(channel)
        await document.addSubscriber(session)

        await expect { !channel.events(kind: .snapshot).isEmpty }
        let snapshot = try XCTUnwrap(channel.events(kind: .snapshot).first)
        // A snapshot always declares base 0 — that is what makes it epoch-independent and lets a
        // post-restart client converge in ONE frame instead of two.
        XCTAssertEqual(snapshot.base, 0)
        let liveStateNum = await document.stateNum
        let liveEpoch = await document.epoch
        XCTAssertEqual(snapshot.new, liveStateNum)
        XCTAssertEqual(snapshot.epoch, liveEpoch)
        let state = try WorkspaceStateCodec.decodeSnapshot(snapshot.payload)
        XCTAssertEqual(PaneLiveness(paneID: paneA, entries: state)?.liveTitle, "main.go - NVIM")
        session.close()
    }

    func testAChangeAfterTheAckArrivesAsADiffFromTheAckedBase() async throws {
        let channel = RecordingChannel()
        let document = HostWorkspaceDocument()
        let session = makeSession(channel)
        await document.addSubscriber(session)
        await expect { !channel.events(kind: .snapshot).isEmpty }
        let firstNum = try XCTUnwrap(channel.events(kind: .snapshot).first).new
        await document.handle(ack: firstNum, from: session.id)

        await document.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "zsh"))
        await expect { !channel.events(kind: .diff).isEmpty }
        let diff = try XCTUnwrap(channel.events(kind: .diff).first)
        // The base is what the client ACKED — the entire correctness argument. Basing on the last
        // SENT state instead is how a lost frame becomes permanent divergence.
        XCTAssertEqual(diff.base, firstNum)
        let liveStateNum = await document.stateNum
        XCTAssertEqual(diff.new, liveStateNum)
        let decoded = try WorkspaceStateCodec.decodeDiff(diff.payload)
        XCTAssertTrue(decoded.sets.contains { $0.key.field == WorkspacePaneField.liveTitle })
        session.close()
    }

    func testANoOpMutationNeitherBumpsTheVersionNorSendsAFrame() async throws {
        let channel = RecordingChannel()
        let document = HostWorkspaceDocument()
        let record = PaneLiveness(paneID: paneA, liveTitle: "zsh")
        await document.merge(paneLiveness: record)
        let session = makeSession(channel)
        await document.addSubscriber(session)
        await expect { !channel.events(kind: .snapshot).isEmpty }
        let num = await document.stateNum
        await document.handle(ack: num, from: session.id)

        // The reconciler re-captures every pane on a tick. An unchanged capture MUST be silent —
        // otherwise an idle host churns a version, and a frame per subscriber, forever.
        for _ in 0..<20 { await document.merge(paneLiveness: record) }
        let unchanged = await document.stateNum
        XCTAssertEqual(unchanged, num)
        // Give a would-be frame every chance to appear before asserting it did not.
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(channel.events(kind: .diff).isEmpty)
        session.close()
    }

    func testUpdatesArrivingBeforeTheAckCoalesceIntoOneDiff() async throws {
        let channel = RecordingChannel()
        let document = HostWorkspaceDocument()
        let session = makeSession(channel)
        await document.addSubscriber(session)
        await expect { !channel.events(kind: .snapshot).isEmpty }
        let firstNum = await document.stateNum
        await document.handle(ack: firstNum, from: session.id)
        await expect { session.outstandingForTesting == nil }

        // 500 versions with no ack in between. Depth-1 coalescing means the pending offer is
        // DISCARDED AND RECOMPUTED, never queued: host memory stays O(one state) per client no
        // matter how far behind the client is, which is what makes a sleeping iPhone free.
        for index in 0..<500 {
            await document.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "step \(index)"))
        }
        await expect { !channel.events(kind: .diff).isEmpty }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(channel.events(kind: .diff).count, 1, "an unacked client must not accumulate frames")

        // …and the LATEST value still lands once the ack arrives.
        await document.handle(ack: channel.events(kind: .diff)[0].new, from: session.id)
        await expect { channel.events(kind: .diff).count == 2 }
        let latest = try WorkspaceStateCodec.decodeDiff(channel.events(kind: .diff)[1].payload)
        let title = latest.sets.first { $0.key.field == WorkspacePaneField.liveTitle }?.value
        XCTAssertEqual(title.flatMap { WorkspaceStateCodec.decodeString($0) }, "step 499")
        session.close()
    }

    func testAppliedDiffsReconstructTheHostStateExactly() async throws {
        let channel = RecordingChannel()
        let document = HostWorkspaceDocument()
        let session = makeSession(channel)
        await document.addSubscriber(session)
        await expect { !channel.events(kind: .snapshot).isEmpty }

        var mirror = HostWorkspaceState()
        var applied = 0
        for step in 0..<12 {
            // Drain whatever is pending, applying it exactly as a client would.
            let seen = applied
            await expect({ channel.events.count > seen }, "a frame after \(seen)")
            for event in channel.events.dropFirst(applied) {
                if event.kind == WorkspaceEventKind.snapshot.rawValue {
                    mirror = try WorkspaceStateCodec.decodeSnapshot(event.payload)
                } else if event.kind == WorkspaceEventKind.diff.rawValue {
                    mirror = try mirror.applying(WorkspaceStateCodec.decodeDiff(event.payload))
                }
                applied += 1
                await document.handle(ack: event.new, from: session.id)
            }
            await document.merge(paneLiveness: PaneLiveness(
                paneID: step.isMultiple(of: 2) ? paneA : paneB,
                liveTitle: "t\(step)",
                cwd: "/tmp/\(step)",
                commandRunning: step.isMultiple(of: 3),
            ))
        }
        let seenAtEnd = applied
        await expect({ channel.events.count > seenAtEnd }, "the final frame")
        for event in channel.events.dropFirst(applied)
            where event.kind == WorkspaceEventKind.diff.rawValue
        {
            mirror = try mirror.applying(WorkspaceStateCodec.decodeDiff(event.payload))
        }
        let hostState = await document.snapshot
        XCTAssertEqual(mirror, hostState)
        session.close()
    }

    // MARK: Epoch

    func testANewEpochSendsResetThenConvergesInOneSnapshot() async throws {
        // Drive the session directly: an epoch belongs to a document INSTANCE, and the case under
        // test is one client outliving a hostd restart.
        let channel = RecordingChannel()
        let session = makeSession(channel)
        session.start()
        let epochOne = UUID()
        var state = HostWorkspaceState()
        state.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "before"))
        session.deliver(epoch: epochOne, stateNum: 5, state: state)
        await expect { !channel.events(kind: .snapshot).isEmpty }
        session.note(ack: 5)

        let epochTwo = UUID()
        var restored = HostWorkspaceState()
        restored.merge(paneLiveness: PaneLiveness(paneID: paneA, liveness: .dead, liveTitle: "after"))
        session.deliver(epoch: epochTwo, stateNum: 1, state: restored)

        await expect { !channel.events(kind: .reset).isEmpty }
        let reset = try XCTUnwrap(channel.events(kind: .reset).first)
        // The reset carries the NEW epoch and zeroes both state numbers — a restarted daemon counts
        // `stateNum` back up, so without this a client one behind would accept a delta computed
        // against a completely different document.
        XCTAssertEqual(reset.epoch, epochTwo)
        XCTAssertEqual(reset.base, 0)
        XCTAssertEqual(reset.new, 0)

        await expect { channel.events(kind: .snapshot).count == 2 }
        let second = channel.events(kind: .snapshot)[1]
        XCTAssertEqual(second.epoch, epochTwo)
        XCTAssertEqual(second.new, 1)
        // ONE snapshot after the reset, not a snapshot then a corrective diff.
        XCTAssertEqual(
            try WorkspaceStateCodec.decodeSnapshot(second.payload),
            restored,
        )
        session.close()
    }

    // MARK: Resync

    func testAnAckForAnUnretainedStateFallsBackToASnapshot() async {
        let channel = RecordingChannel()
        let session = makeSession(channel)
        session.start()
        let epoch = UUID()
        var state = HostWorkspaceState()
        state.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "one"))
        session.deliver(epoch: epoch, stateNum: 1, state: state)
        await expect { channel.events(kind: .snapshot).count == 1 }

        // An ack naming a state this subscriber never sent. Guessing a base here is how a diff
        // applies cleanly against the wrong document and corrupts with no detector.
        session.note(ack: 9999)
        state.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "two"))
        session.deliver(epoch: epoch, stateNum: 2, state: state)
        await expect { channel.events(kind: .snapshot).count == 2 }
        XCTAssertTrue(channel.events(kind: .diff).isEmpty)
        session.close()
    }

    func testResubscribeFromZeroReSnapshots() async {
        let channel = RecordingChannel()
        let request = subscribe()
        let session = makeSession(channel, request)
        session.start()
        let epoch = UUID()
        var state = HostWorkspaceState()
        state.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "one"))
        session.deliver(epoch: epoch, stateNum: 1, state: state)
        await expect { channel.events(kind: .snapshot).count == 1 }
        session.note(ack: 1)

        // Re-sending `subscribe` IS the resync verb — there is deliberately no separate "resend".
        session.note(resubscribe: WorkspaceSubscribe(
            clientInstanceID: request.clientInstanceID,
            clientKind: request.clientKind,
        ))
        session.deliver(epoch: epoch, stateNum: 2, state: state)
        await expect { channel.events(kind: .snapshot).count == 2 }
        session.close()
    }

    func testResubscribeAtARetainedStateResumesWithADiff() async throws {
        let channel = RecordingChannel()
        let request = subscribe()
        let session = makeSession(channel, request)
        session.start()
        let epoch = UUID()
        var state = HostWorkspaceState()
        state.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "one"))
        session.deliver(epoch: epoch, stateNum: 1, state: state)
        await expect { channel.events(kind: .snapshot).count == 1 }

        // The client says exactly where it is, and we still retain that state — so reconnect costs
        // one diff bounded by the SIZE of the document, never by the duration of the absence.
        session.note(resubscribe: WorkspaceSubscribe(
            clientInstanceID: request.clientInstanceID,
            clientKind: request.clientKind,
            knownEpoch: epoch,
            knownStateNum: 1,
        ))
        state.merge(paneLiveness: PaneLiveness(paneID: paneB, liveTitle: "two"))
        session.deliver(epoch: epoch, stateNum: 2, state: state)
        await expect { !channel.events(kind: .diff).isEmpty }
        let diff = try XCTUnwrap(channel.events(kind: .diff).first)
        XCTAssertEqual(diff.base, 1)
        XCTAssertEqual(channel.events(kind: .snapshot).count, 1)
        session.close()
    }

    func testResubscribeWithAForeignEpochReSnapshots() async {
        let channel = RecordingChannel()
        let request = subscribe()
        let session = makeSession(channel, request)
        session.start()
        let epoch = UUID()
        var state = HostWorkspaceState()
        state.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "one"))
        session.deliver(epoch: epoch, stateNum: 1, state: state)
        await expect { channel.events(kind: .snapshot).count == 1 }

        // Right stateNum, WRONG document. A diff based on this would apply cleanly and be wrong.
        session.note(resubscribe: WorkspaceSubscribe(
            clientInstanceID: request.clientInstanceID,
            clientKind: request.clientKind,
            knownEpoch: UUID(),
            knownStateNum: 1,
        ))
        state.merge(paneLiveness: PaneLiveness(paneID: paneB, liveTitle: "two"))
        session.deliver(epoch: epoch, stateNum: 2, state: state)
        await expect { channel.events(kind: .snapshot).count == 2 }
        XCTAssertTrue(channel.events(kind: .diff).isEmpty)
        session.close()
    }

    func testAStateBeyondTheRetentionWindowFallsBackToASnapshot() async {
        let channel = RecordingChannel()
        let request = subscribe()
        let session = makeSession(channel, request)
        session.start()
        let epoch = UUID()
        var state = HostWorkspaceState()
        // Push more versions than the retention window, acking each so the next may ship.
        for step in 1...(WorkspaceChannelSession.retainedSentStates + 3) {
            state.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "v\(step)"))
            session.deliver(epoch: epoch, stateNum: Int64(step), state: state)
            await expect { channel.events.count >= step }
            session.note(ack: Int64(step))
        }
        // Now claim to be at version 1, long since evicted from the window.
        session.note(resubscribe: WorkspaceSubscribe(
            clientInstanceID: request.clientInstanceID,
            clientKind: request.clientKind,
            knownEpoch: epoch,
            knownStateNum: 1,
        ))
        state.merge(paneLiveness: PaneLiveness(paneID: paneB, liveTitle: "late"))
        session.deliver(epoch: epoch, stateNum: 99, state: state)
        await expect { channel.events(kind: .snapshot).count >= 2 }
        session.close()
    }

    // MARK: Presence

    func testPresenceNeverTouchesTheStateNumbers() async throws {
        let channel = RecordingChannel()
        let document = HostWorkspaceDocument()
        let session = makeSession(channel, subscribe(clientKind: 1, label: "iPhone"))
        await document.addSubscriber(session)
        await expect { !channel.events(kind: .presence).isEmpty }
        for frame in channel.events(kind: .presence) {
            // A kind-2 frame that advanced `stateNum` would make the host retire, via `assumedAcked`,
            // a diff it never sent — permanent silent divergence on the very first rename.
            XCTAssertEqual(frame.base, 0)
            XCTAssertEqual(frame.new, 0)
        }
        let roster = try WorkspacePresenceRoster.decode(
            XCTUnwrap(channel.events(kind: .presence).last).payload,
        )
        XCTAssertEqual(roster.clients.count, 1)
        XCTAssertEqual(roster.clients.first?.clientKind, 1)
        XCTAssertEqual(roster.clients.first?.label, "iPhone")
        session.close()
    }

    func testTwoConnectionsFromOneDeviceAreTwoIdentities() async {
        let first = RecordingChannel()
        let second = RecordingChannel()
        let document = HostWorkspaceDocument()
        // Same label — two windows of one app. They must still be two roster entries, because the
        // identity is minted per CONNECTION, not per install.
        let sessionA = makeSession(first, subscribe(label: "mac-studio"))
        let sessionB = makeSession(second, subscribe(label: "mac-studio"))
        await document.addSubscriber(sessionA)
        await document.addSubscriber(sessionB)
        await expect {
            (try? WorkspacePresenceRoster.decode(first.events(kind: .presence).last?.payload ?? Data()))?
                .clients.count == 2
        }
        sessionA.close()
        sessionB.close()
    }

    func testLeavingBroadcastsTheNullRoster() async {
        let first = RecordingChannel()
        let second = RecordingChannel()
        let document = HostWorkspaceDocument()
        let sessionA = makeSession(first, subscribe(label: "mac"))
        let sessionB = makeSession(second, subscribe(label: "phone"))
        await document.addSubscriber(sessionA)
        await document.addSubscriber(sessionB)
        await expect {
            (try? WorkspacePresenceRoster.decode(first.events(kind: .presence).last?.payload ?? Data()))?
                .clients.count == 2
        }
        await document.removeSubscriber(id: sessionB.id)
        // A roster that simply STOPS arriving is indistinguishable from a stalled host, so the
        // departure is announced rather than implied.
        await expect {
            (try? WorkspacePresenceRoster.decode(first.events(kind: .presence).last?.payload ?? Data()))?
                .clients.count == 1
        }
        sessionA.close()
    }

    // MARK: Lifecycle

    func testADeadChannelDropsItsSubscriberWithoutThrowing() async throws {
        let channel = RecordingChannel()
        let document = HostWorkspaceDocument()
        let session = makeSession(channel)
        await document.addSubscriber(session)
        await expect { !channel.events(kind: .snapshot).isEmpty }
        channel.kill()
        // A link that dies takes the channel with it; the client resubscribes. There is deliberately
        // no retransmit path to get stuck in.
        await document.merge(paneLiveness: PaneLiveness(paneID: paneA, liveTitle: "after death"))
        try await Task.sleep(for: .milliseconds(80))
        await document.removeSubscriber(id: session.id)
        let remaining = await document.subscriberCount
        XCTAssertEqual(remaining, 0)
    }

    func testRemovePanesReapsAPaneTheHostNoLongerKnows() async {
        let document = HostWorkspaceDocument()
        await document.merge(paneLiveness: PaneLiveness(paneID: paneA))
        await document.merge(paneLiveness: PaneLiveness(paneID: paneB))
        let before = await document.stateNum
        let reaped = await document.removePanes(keeping: [paneA])
        XCTAssertTrue(reaped)
        let after = await document.snapshot
        XCTAssertNotNil(after[WorkspaceKey(.pane, paneA, WorkspacePaneField.liveness)])
        XCTAssertNil(after[WorkspaceKey(.pane, paneB, WorkspacePaneField.liveness)])
        let afterNum = await document.stateNum
        XCTAssertGreaterThan(afterNum, before)
        // Reaping nothing is not a version.
        let reapedAgain = await document.removePanes(keeping: [paneA])
        XCTAssertFalse(reapedAgain)
    }

    func testProjectGitSummaryIsKeyedByProjectNotPane() async {
        let document = HostWorkspaceDocument()
        let projectID = UUID()
        let stored = await document.setProject(id: projectID, key: "/repo", gitSummary: Data([1, 2, 3]))
        XCTAssertTrue(stored)
        let state = await document.snapshot
        XCTAssertEqual(
            state[WorkspaceKey(.project, projectID, WorkspaceProjectField.key)],
            WorkspaceStateCodec.encodeString("/repo"),
        )
        XCTAssertEqual(state[WorkspaceKey(.project, projectID, WorkspaceProjectField.gitSummary)], Data([1, 2, 3]))
        // Clearing the summary removes the field without removing the project.
        let cleared = await document.setProject(id: projectID, key: "/repo", gitSummary: nil)
        XCTAssertTrue(cleared)
        let afterClear = await document.snapshot
        XCTAssertNil(afterClear[WorkspaceKey(.project, projectID, WorkspaceProjectField.gitSummary)])
        XCTAssertNotNil(afterClear[WorkspaceKey(.project, projectID, WorkspaceProjectField.key)])
    }
}
