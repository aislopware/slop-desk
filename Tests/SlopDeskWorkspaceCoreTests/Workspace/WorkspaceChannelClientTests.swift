import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``WorkspaceChannelClient`` driven over an in-memory control channel — the whole loop with no
/// socket: open → await the ack → subscribe → apply → ack.
///
/// Every assertion POLLS rather than awaiting a stream: a test that suspends on `iterator.next()`
/// when the frame never comes strands the whole xctest strand for the harness timeout instead of
/// failing in seconds (DECISIONS Phase-4 ruling 8).
@MainActor
final class WorkspaceChannelClientTests: XCTestCase {
    // MARK: - Doubles

    /// One direction of a channel pair. Sends land in a lock-guarded log; `deliver` pushes an
    /// inbound message at the client.
    private final class PipeChannel: MessageChannel, @unchecked Sendable {
        let channel: Channel = .control
        let inbound: AsyncThrowingStream<WireMessage, Error>
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        private let lock = NSLock()
        private var sent: [WireMessage] = []
        private var failSends = false

        init() {
            (inbound, continuation) = AsyncThrowingStream.makeStream(of: WireMessage.self)
        }

        func send(_ message: WireMessage) async throws {
            await Task.yield()
            // A synchronous helper that RETURNS the verdict: `NSLock` is unavailable from an async
            // context, and holding one across a suspension is the mistake that ban exists to catch.
            guard record(message) else { throw SlopDeskTransportError.notConnected("test channel closed") }
        }

        private func record(_ message: WireMessage) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !failSends else { return false }
            sent.append(message)
            return true
        }

        func deliver(_ message: WireMessage) { continuation.yield(message) }
        func endStream() { continuation.finish() }

        /// Makes every subsequent `send` throw WITHOUT ending the inbound stream — a mux write error
        /// on a channel the client still believes is live.
        func failSubsequentSends() {
            lock.lock()
            failSends = true
            lock.unlock()
        }

        var sentMessages: [WireMessage] {
            lock.lock()
            defer { lock.unlock() }
            return sent
        }

        /// Every type-17 request, decoded to `(verb, payload)`.
        var requests: [(verb: UInt8, payload: Data)] {
            sentMessages.compactMap {
                guard case let .workspaceRequest(_, verb, payload) = $0 else { return nil }
                return (verb, payload)
            }
        }

        func requests(verb: WorkspaceRequestVerb) -> [Data] {
            requests.filter { $0.verb == verb.rawValue }.map(\.payload)
        }
    }

    /// A rig: the channel, the client, and the knobs the host end would turn.
    @MainActor
    private struct Rig {
        let pipe: PipeChannel
        let box: WorkspaceMirrorBox
        let client: WorkspaceChannelClient
        let released: () -> [UInt32]
        let acceptOpen: (Bool) -> Void
        let opens: () -> Int
    }

    private let epoch = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let pane = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// - Parameter autoAccept: `nil` withholds the verdict until `acceptOpen` is called — which is
    ///   how the "no request before the ack" rule is proved.
    @MainActor
    private func makeRig(autoAccept: Bool? = true, channelID: UInt32 = 7) -> Rig {
        let pipe = PipeChannel()
        let verdict = VerdictBox()
        if let autoAccept { verdict.set(autoAccept) }
        let releasedIDs = Box<[UInt32]>([])
        let openCount = Box(0)

        let box = WorkspaceMirrorBox()
        let client = WorkspaceChannelClient(
            box: box,
            clientInstanceID: UUID(uuidString: "CCCCCCCC-1111-2222-3333-444444444444")!,
            clientKind: .macOS,
            label: "mac-studio",
            open: {
                openCount.mutate { $0 += 1 }
                return WorkspaceChannelClient.Handle(
                    channelID: channelID,
                    control: pipe,
                    awaitAccepted: { await verdict.value },
                )
            },
            close: { id in releasedIDs.mutate { $0.append(id) } },
        )
        return Rig(
            pipe: pipe,
            box: box,
            client: client,
            released: { releasedIDs.value },
            acceptOpen: { verdict.set($0) },
            opens: { openCount.value },
        )
    }

    /// A verdict that can be supplied AFTER a waiter has already suspended on it.
    private final class VerdictBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved: Bool?

        func set(_ accepted: Bool) {
            lock.lock()
            resolved = accepted
            lock.unlock()
        }

        private func peek() -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return resolved
        }

        var value: Bool {
            get async {
                while true {
                    if let current = peek() { return current }
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
        }
    }

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ initial: Value) { stored = initial }
        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func mutate(_ body: (inout Value) -> Void) {
            lock.lock()
            body(&stored)
            lock.unlock()
        }
    }

    // MARK: - Helpers

    /// Polls `condition` until true or the deadline. Asserts rather than returning, so a caller can
    /// never accidentally ignore the result.
    private func expect(
        _ description: String,
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await MainActor.run(body: condition) { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    /// Asserts `condition` STAYS false for a short window — the shape "nothing happened yet".
    private func expectNever(
        _ description: String,
        within: Duration = .milliseconds(120),
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if await MainActor.run(body: condition) {
                XCTFail("unexpectedly observed \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func snapshot(_ entries: [WorkspaceEntry], stateNum: Int64) -> WireMessage {
        .workspaceEvent(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: stateNum,
            payload: WorkspaceStateCodec.encodeSnapshot(HostWorkspaceState(entries)),
        )
    }

    private func diff(_ diff: WorkspaceStateDiff, base: Int64, new: Int64, epoch: UUID? = nil) -> WireMessage {
        .workspaceEvent(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: epoch ?? self.epoch,
            baseStateNum: base,
            newStateNum: new,
            payload: WorkspaceStateCodec.encodeDiff(diff),
        )
    }

    private func paneEntries(title: String, fresh: Bool) -> [WorkspaceEntry] {
        PaneLiveness(paneID: pane, liveness: .attached, liveTitle: title, titleFresh: fresh).entries()
    }

    // MARK: - Open order (DECISIONS Phase-4 ruling 7)

    /// The rule, stated as a test: NOTHING goes out until the host's `channelOpenAck` lands.
    ///
    /// `channelOpen` is announced on DATA while requests ride CONTROL, so a subscribe that races the
    /// host's registration of the control sub-channel is silently DROPPED and this client waits for
    /// a snapshot forever. The bug presents as a flake, so the ordering has to be structural.
    func testNoRequestIsSentBeforeTheOpenAckArrives() async {
        let rig = await makeRig(autoAccept: nil)
        await MainActor.run { rig.client.start() }

        await expect("the open to have been attempted") { rig.opens() == 1 }
        await expectNever("a request sent before the ack") { !rig.pipe.requests.isEmpty }

        await MainActor.run { rig.acceptOpen(true) }
        await expect("subscribe after the ack") { !rig.pipe.requests(verb: .subscribe).isEmpty }
    }

    /// A refusal is a definite answer — the flag is off on that host, or a subscriber already exists
    /// on this connection. The client releases the channel and stops; it does not retry-storm.
    func testARefusedOpenReleasesTheChannelAndNeverRetries() async {
        let rig = await makeRig(autoAccept: false)
        await MainActor.run { rig.client.start() }

        await expect("the refusal to settle") { rig.client.state == .refused }
        let releasedAfterRefusal = await MainActor.run { rig.released() }
        XCTAssertEqual(releasedAfterRefusal, [7], "the refused channel is released")
        XCTAssertTrue(rig.pipe.requests.isEmpty, "a refused channel is never spoken to")

        await MainActor.run { rig.client.start() }
        await expectNever("a retry after a refusal") { rig.opens() > 1 }
    }

    // MARK: - Subscribe → snapshot → ack

    func testTheFirstSubscribeDeclaresNothingKnown() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }

        let payload = rig.pipe.requests(verb: .subscribe)[0]
        let request = try? WorkspaceSubscribe.decode(payload)

        XCTAssertEqual(request?.knownStateNum, 0, "0 is the 'I know nothing' sentinel")
        XCTAssertEqual(request?.knownEpoch, WireMessage.newSessionID)
        XCTAssertEqual(request?.label, "mac-studio")
        XCTAssertEqual(request?.clientKind, WorkspaceClientKind.macOS.rawValue)
    }

    func testASnapshotIsAppliedAndAcked() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }

        rig.pipe.deliver(snapshot(paneEntries(title: "main.swift - NVIM", fresh: true), stateNum: 4))

        await expect("the ack") { !rig.pipe.requests(verb: .ack).isEmpty }
        let acked = rig.pipe.requests(verb: .ack).compactMap { WorkspaceStateCodec.decodeI64($0) }
        XCTAssertEqual(acked, [4])
        await MainActor.run {
            XCTAssertEqual(rig.client.state, .live(4))
            XCTAssertEqual(
                rig.box.mirror.string(.pane, self.pane, WorkspacePaneField.liveTitle),
                "main.swift - NVIM",
            )
            XCTAssertTrue(rig.box.mirror.bool(.pane, self.pane, WorkspacePaneField.titleFresh))
        }
    }

    func testADiffAdvancesTheMirrorAndIsAckedInTurn() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(paneEntries(title: "old", fresh: true), stateNum: 1))
        await expect("the first ack") { !rig.pipe.requests(verb: .ack).isEmpty }

        rig.pipe.deliver(diff(
            WorkspaceStateDiff(sets: [WorkspaceEntry(
                key: WorkspaceKey(.pane, pane, WorkspacePaneField.liveTitle),
                value: WorkspaceStateCodec.encodeString("new"),
            )]),
            base: 1,
            new: 2,
        ))

        await expect("the second ack") { rig.pipe.requests(verb: .ack).count == 2 }
        let acked = rig.pipe.requests(verb: .ack).compactMap { WorkspaceStateCodec.decodeI64($0) }
        XCTAssertEqual(acked, [1, 2])
        await MainActor.run {
            XCTAssertEqual(rig.box.mirror.string(.pane, self.pane, WorkspacePaneField.liveTitle), "new")
        }
    }

    /// A mis-based frame is answered with a fresh `subscribe` — the resync verb — carrying where the
    /// mirror ACTUALLY is, not where the host guessed.
    func testAMisBasedDiffResubscribesFromWhatTheMirrorHolds() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(paneEntries(title: "held", fresh: true), stateNum: 3))
        await expect("the ack") { !rig.pipe.requests(verb: .ack).isEmpty }

        // Based on 9 — a state this client never had.
        rig.pipe.deliver(diff(
            WorkspaceStateDiff(deletes: [WorkspaceKey(.pane, pane, WorkspacePaneField.liveTitle)]),
            base: 9,
            new: 10,
        ))

        await expect("the resubscribe") { rig.pipe.requests(verb: .subscribe).count == 2 }
        let resub = try? WorkspaceSubscribe.decode(rig.pipe.requests(verb: .subscribe)[1])
        XCTAssertEqual(resub?.knownStateNum, 3, "we hold 3 and say so")
        XCTAssertEqual(resub?.knownEpoch, epoch)
        await MainActor.run {
            XCTAssertEqual(
                rig.box.mirror.string(.pane, self.pane, WorkspacePaneField.liveTitle), "held",
                "the rejected frame changed nothing",
            )
        }
    }

    /// The epoch's job: a delta from a restarted daemon whose numbers happen to line up must be
    /// refused, and the answer is a resubscribe rather than silent corruption.
    func testADiffFromAnotherEpochResubscribesRatherThanApplying() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(paneEntries(title: "held", fresh: true), stateNum: 1))
        await expect("the ack") { !rig.pipe.requests(verb: .ack).isEmpty }

        rig.pipe.deliver(diff(
            WorkspaceStateDiff(sets: [WorkspaceEntry(
                key: WorkspaceKey(.pane, pane, WorkspacePaneField.liveTitle),
                value: WorkspaceStateCodec.encodeString("other document"),
            )]),
            base: 1,
            new: 2,
            epoch: UUID(),
        ))

        await expect("the resubscribe") { rig.pipe.requests(verb: .subscribe).count == 2 }
        await MainActor.run {
            XCTAssertEqual(rig.box.mirror.string(.pane, self.pane, WorkspacePaneField.liveTitle), "held")
        }
    }

    /// A superseded frame is silent: no ack, no resubscribe, no churn.
    func testASupersededDiffProducesNoTraffic() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(paneEntries(title: "held", fresh: true), stateNum: 5))
        await expect("the ack") { !rig.pipe.requests(verb: .ack).isEmpty }

        rig.pipe.deliver(diff(WorkspaceStateDiff(), base: 2, new: 3))

        await expectNever("a second ack or resubscribe") {
            rig.pipe.requests(verb: .ack).count > 1 || rig.pipe.requests(verb: .subscribe).count > 1
        }
    }

    // MARK: - Presence

    func testPresenceIsSentWithAMonotonicClock() async {
        let rig = await makeRig()
        let tab = UUID()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }

        await MainActor.run {
            rig.client.updatePresence(viewingTabID: tab, viewingPaneID: self.pane, cols: 120, rows: 40)
            rig.client.updatePresence(viewingTabID: tab, viewingPaneID: self.pane, cols: 100, rows: 30)
        }

        await expect("both presence frames") { rig.pipe.requests(verb: .presence).count == 2 }
        let updates = rig.pipe.requests(verb: .presence).compactMap { try? WorkspacePresenceUpdate.decode($0) }
        XCTAssertEqual(updates.map(\.presenceClock), [1, 2], "strictly increasing — an older clock is ignored")
        XCTAssertEqual(updates.last?.cols, 100)
        XCTAssertEqual(updates.last?.viewingTabID, tab)
    }

    /// A BURST of view changes reaches the host in issue order.
    ///
    /// The host keeps the newest `presenceClock` and ignores anything older, so an out-of-order
    /// arrival is not a cosmetic race: the roster settles on a view the user has already left, and
    /// nothing later corrects it because the correct update was the one that got ignored. One
    /// detached task per update publishes in SCHEDULING order, which is not issue order — so the
    /// sends are drained by a single task off an ordered queue.
    func testABurstOfPresenceUpdatesArrivesInIssueOrder() async {
        let rig = await makeRig()
        let tabs = (0..<6).map { _ in UUID() }
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }

        await MainActor.run {
            for tab in tabs {
                rig.client.updatePresence(viewingTabID: tab, viewingPaneID: self.pane, cols: 0, rows: 0)
            }
        }

        await expect("every presence frame") { rig.pipe.requests(verb: .presence).count == tabs.count }
        let updates = rig.pipe.requests(verb: .presence).compactMap { try? WorkspacePresenceUpdate.decode($0) }
        XCTAssertEqual(updates.map(\.presenceClock), Array(1...Int64(tabs.count)))
        XCTAssertEqual(updates.map(\.viewingTabID), tabs)
    }

    /// The caller is the reconcile funnel, which fires for a spec edit and a badge tick as readily as
    /// for a tab switch. Only a changed VIEW is news — an unguarded repeat would spend a frame per
    /// reconcile on a workspace nobody is navigating, and run the clock away for nothing.
    func testAnUnchangedViewSendsNothing() async {
        let rig = await makeRig()
        let tab = UUID()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }

        await MainActor.run {
            rig.client.updatePresence(viewingTabID: tab, viewingPaneID: self.pane, cols: 0, rows: 0)
        }
        await expect("the first presence") { rig.pipe.requests(verb: .presence).count == 1 }

        await MainActor.run {
            rig.client.updatePresence(viewingTabID: tab, viewingPaneID: self.pane, cols: 0, rows: 0)
            rig.client.updatePresence(viewingTabID: tab, viewingPaneID: self.pane, cols: 0, rows: 0)
        }
        await expectNever("a second frame for the same view") {
            rig.pipe.requests(verb: .presence).count > 1
        }

        // …and a genuine move still speaks.
        let other = UUID()
        await MainActor.run {
            rig.client.updatePresence(viewingTabID: tab, viewingPaneID: other, cols: 0, rows: 0)
        }
        await expect("the move") { rig.pipe.requests(verb: .presence).count == 2 }
        let updates = rig.pipe.requests(verb: .presence).compactMap { try? WorkspacePresenceUpdate.decode($0) }
        XCTAssertEqual(updates.map(\.presenceClock), [1, 2], "the guard skips the clock too")
    }

    /// A resubscribe resets the host's per-subscriber view along with its base, so what this client
    /// is looking at must be re-asserted rather than waiting for the next UI change.
    func testAResubscribeReAssertsPresence() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(paneEntries(title: "held", fresh: true), stateNum: 1))
        await expect("the ack") { !rig.pipe.requests(verb: .ack).isEmpty }
        await MainActor.run {
            rig.client.updatePresence(viewingTabID: UUID(), viewingPaneID: self.pane, cols: 80, rows: 24)
        }
        await expect("the first presence") { rig.pipe.requests(verb: .presence).count == 1 }

        rig.pipe.deliver(diff(WorkspaceStateDiff(), base: 9, new: 10))

        await expect("presence re-asserted after the resubscribe") { rig.pipe.requests(verb: .presence).count == 2 }
        let updates = rig.pipe.requests(verb: .presence).compactMap { try? WorkspacePresenceUpdate.decode($0) }
        XCTAssertEqual(updates.map(\.presenceClock), [1, 1], "a re-assert repeats the clock, it does not invent one")
    }

    func testAPresenceRosterLandsOnTheMirror() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }

        let roster = WorkspacePresenceRoster(
            clients: [WorkspaceRosterClient(
                clientInstanceID: UUID(), clientKind: WorkspaceClientKind.iOS.rawValue, label: "iPad",
            )],
            panes: [],
        )
        rig.pipe.deliver(.workspaceEvent(
            kind: WorkspaceEventKind.presence.rawValue,
            epoch: epoch, baseStateNum: 0, newStateNum: 0, payload: roster.encode(),
        ))

        await expect("the roster") { rig.box.mirror.roster?.clients.count == 1 }
        await MainActor.run {
            XCTAssertEqual(rig.box.mirror.roster?.clients.first?.label, "iPad")
        }
        await expectNever("an ack for presence") { !rig.pipe.requests(verb: .ack).isEmpty }
    }

    // MARK: - Teardown

    func testTheStreamEndingClosesTheClientAndReleasesTheChannel() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }

        rig.pipe.endStream()

        await expect("the closed state") { rig.client.state == .closed }
        let released = await MainActor.run { rig.released() }
        XCTAssertEqual(released, [7])
    }

    /// Stopping forgets host truth. Keeping it would let a reconnect apply a diff against a document
    /// the host may have replaced; a fresh snapshot is one frame and always correct.
    func testStoppingResetsTheMirrorAndReleasesTheChannel() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(paneEntries(title: "held", fresh: true), stateNum: 1))
        await expect("the ack") { !rig.pipe.requests(verb: .ack).isEmpty }

        await MainActor.run { rig.client.stop() }

        await MainActor.run {
            XCTAssertEqual(rig.client.state, .closed)
            XCTAssertNil(rig.box.mirror.epoch)
            XCTAssertEqual(rig.box.mirror.knownStateNum, 0)
            XCTAssertTrue(rig.box.mirror.entries.isEmpty)
        }
        await expect("the channel to be released") { rig.released() == [7] }
    }

    /// A stop that lands mid-handshake must still release, and must release ONCE. A second close of
    /// the same id would reach into the shared connection pool for a channel a reconnect may already
    /// have rebuilt under that key.
    func testStoppingDuringTheHandshakeReleasesExactlyOnce() async {
        let rig = makeRig(autoAccept: nil)
        rig.client.start()
        await expect("the open") { rig.opens() == 1 }

        rig.client.stop()
        // Let the handshake resolve AFTER the stop — the losing path must find nothing to release.
        rig.acceptOpen(true)

        await expect("the release") { rig.released() == [7] }
        await expectNever("a second release") { rig.released().count > 1 }
        XCTAssertTrue(rig.pipe.requests.isEmpty, "a stopped channel is never subscribed to")
    }

    // MARK: - Untrusted frames

    /// Forward tolerance, on the live channel: a kind this build does not know costs one dropped
    /// frame. There is no version negotiation on this wire, so tearing the channel down would make a
    /// newer host unusable rather than merely partially understood.
    func testAnUnknownEventKindDoesNotDisturbTheSubscription() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(paneEntries(title: "held", fresh: true), stateNum: 1))
        await expect("the ack") { !rig.pipe.requests(verb: .ack).isEmpty }

        rig.pipe.deliver(.workspaceEvent(
            kind: 200, epoch: epoch, baseStateNum: 0, newStateNum: 0, payload: Data([0xFF]),
        ))
        rig.pipe.deliver(diff(
            WorkspaceStateDiff(sets: [WorkspaceEntry(
                key: WorkspaceKey(.pane, pane, WorkspacePaneField.cwd),
                value: WorkspaceStateCodec.encodeString("/after"),
            )]),
            base: 1,
            new: 2,
        ))

        await expect("the channel still works") { rig.pipe.requests(verb: .ack).count == 2 }
        await MainActor.run {
            XCTAssertEqual(rig.box.mirror.string(.pane, self.pane, WorkspacePaneField.cwd), "/after")
        }
    }

    /// The channel carries workspace traffic and nothing else, but a stray frame must not stall the
    /// loop — the guard is a `continue`, not a `break`.
    func testANonWorkspaceMessageIsSkipped() async {
        let rig = await makeRig()
        await MainActor.run { rig.client.start() }
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }

        rig.pipe.deliver(.title("stray"))
        rig.pipe.deliver(snapshot(paneEntries(title: "held", fresh: true), stateNum: 1))

        await expect("the snapshot still lands") { !rig.pipe.requests(verb: .ack).isEmpty }
    }

    // MARK: - An optimistic patch never outlives its intent

    /// A layout the host holds, so `stageIntent` has a topology to apply an intent against.
    private func layoutEntries() -> (entries: [WorkspaceEntry], tab: TabID) {
        let leaf = PaneID(raw: pane)
        let tab = Tab(id: TabID(), title: "one", root: .leaf(leaf), activePane: leaf)
        let session = Session(
            id: SessionID(),
            name: "Local",
            tabs: [tab],
            specs: [leaf: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: TreeWorkspace(
            sessions: [session], activeSessionID: session.id,
        )))
        return (state.sortedEntries, tab.id)
    }

    /// A write that never left the machine leaves NOTHING staged.
    ///
    /// The patch takes precedence over host truth on every read, and no `intentResult` can ever
    /// arrive for a request the host was never sent — so a patch kept here would render a rename
    /// only this client can see, across every subsequent snapshot and diff, forever.
    func testAFailedIntentSendDropsItsOptimisticPatchImmediately() async {
        let rig = makeRig()
        let layout = layoutEntries()
        rig.client.start()
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(layout.entries, stateNum: 1))
        await expect("the channel to go live") { rig.client.state == .live(1) }

        rig.pipe.failSubsequentSends()
        let staged = rig.client.send(
            intent: .renameTab, args: WorkspaceIntentArgs.encode(id: layout.tab.raw, name: "renamed"),
        )
        XCTAssertTrue(staged, "the patch is staged optimistically before the write is attempted")

        await expect("the failed intent's patch to be dropped") { rig.box.pendingIntentCount == 0 }
        XCTAssertEqual(
            rig.box.mirror.topology?.tree.sessions.first?.tabs.first?.title, "one",
            "the layout snapped back to host truth rather than freezing on the optimistic title",
        )
    }

    /// A host that took the intent and never answered: the next document frame sweeps the patch.
    ///
    /// The sweep has to happen BEFORE the frame is folded in. A patch outranks host truth on every
    /// read, so an expired one left in place would make this very frame invisible for exactly the
    /// keys it covers — the frozen disagreement stated as a render.
    func testAnUnansweredIntentPatchIsSweptByTheNextHostFrame() async {
        let rig = makeRig()
        let layout = layoutEntries()
        // A clock the test owns, so the three-second deadline needs no three-second sleep — and the
        // self-driving backstop disarmed, so the FRAME is provably what swept the patch.
        let clock = Box(1000.0)
        rig.client.now = { clock.value }
        rig.client.pendingSweepDelay = nil
        rig.client.start()
        await expect("subscribe") { !rig.pipe.requests(verb: .subscribe).isEmpty }
        rig.pipe.deliver(snapshot(layout.entries, stateNum: 1))
        await expect("the channel to go live") { rig.client.state == .live(1) }

        XCTAssertTrue(rig.client.send(
            intent: .renameTab,
            args: WorkspaceIntentArgs.encode(id: layout.tab.raw, name: "renamed"),
            now: clock.value,
        ))
        await expect("the intent to reach the wire") { !rig.pipe.requests(verb: .intent).isEmpty }
        XCTAssertEqual(
            rig.box.mirror.topology?.tree.sessions.first?.tabs.first?.title, "renamed",
            "the optimistic patch is what the user is looking at while the host is asked",
        )

        clock.mutate { $0 += HostWorkspaceMirror.pendingTimeout }
        rig.pipe.deliver(diff(
            WorkspaceStateDiff(sets: [WorkspaceEntry(
                key: WorkspaceKey(.pane, pane, WorkspacePaneField.cwd),
                value: WorkspaceStateCodec.encodeString("/after"),
            )]),
            base: 1,
            new: 2,
        ))

        await expect("the unanswered patch to be swept") { rig.box.pendingIntentCount == 0 }
        XCTAssertEqual(
            rig.box.mirror.topology?.tree.sessions.first?.tabs.first?.title, "one",
            "with the patch gone the row shows what the host actually says",
        )
    }
}
