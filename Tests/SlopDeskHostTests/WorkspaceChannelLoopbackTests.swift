import Foundation
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskProtocol
@testable import SlopDeskTransport
@testable import SlopDeskWorkspaceModel

/// A pair of in-memory ``MuxByteLink``s that pipe bytes to each other — a headless substitute for
/// two `NWConnection`s, so the whole `channelOpen` → route → subscribe → snapshot path runs without
/// a socket. (The transport suite has its own copy; targets cannot share test support files.)
final class LoopbackMuxLink: MuxByteLink, @unchecked Sendable {
    private let outbound: AsyncThrowingStream<Data, Error>.Continuation
    private let inbound: AsyncThrowingStream<Data, Error>
    private var peerInbound: AsyncThrowingStream<Data, Error>.Continuation?

    private init(
        inbound: AsyncThrowingStream<Data, Error>,
        outbound: AsyncThrowingStream<Data, Error>.Continuation,
    ) {
        self.inbound = inbound
        self.outbound = outbound
    }

    static func pair() -> (LoopbackMuxLink, LoopbackMuxLink) {
        var aInC: AsyncThrowingStream<Data, Error>.Continuation!
        let aIn = AsyncThrowingStream<Data, Error> { aInC = $0 }
        var bInC: AsyncThrowingStream<Data, Error>.Continuation!
        let bIn = AsyncThrowingStream<Data, Error> { bInC = $0 }
        let a = LoopbackMuxLink(inbound: aIn, outbound: aInC)
        let b = LoopbackMuxLink(inbound: bIn, outbound: bInC)
        a.peerInbound = bInC
        b.peerInbound = aInC
        return (a, b)
    }

    var receiveChunks: AsyncThrowingStream<Data, Error> { inbound }

    func send(_ data: Data) { peerInbound?.yield(data) }

    /// SYNCHRONOUS enqueue — a `Task` hop here would scramble per-channel FIFO.
    func sendPipelined(_ data: Data) { peerInbound?.yield(data) }

    func close() {
        peerInbound?.finish()
        outbound.finish()
    }
}

/// End-to-end over a real mux: a `channelOpen` with `channelClass == 1` must reach the workspace
/// handler and NEVER the PTY spawn path.
///
/// The whole design leans on that separation. `spawnMuxChannel`'s critical section — the JOIN route
/// and the detached-store claim — is what guarantees ONE shell per sessionID; the workspace route is
/// placed BEFORE it precisely so that reasoning stays untouched.
/// A test that called the handler directly would prove the handler works and say nothing about the
/// decision, which is the part that can regress.
final class WorkspaceChannelLoopbackTests: XCTestCase {
    private struct Rig {
        let server: HostServer
        let client: MuxNWConnection
        let host: MuxNWConnection
        let directory: URL
    }

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
    }

    private func makeRig() async -> Rig {
        // A REAL store, pointed at a scratch directory. Never the default location: `load()` mints
        // and the persist sink writes, and one test doing either against Application Support would
        // silently replace a workspace somebody is using.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("slopdesk-workspace-rig-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let server = HostServer(
            port: 0,
            workspaceStore: HostWorkspaceStore(
                fileURL: directory.appendingPathComponent("workspace-state.json"),
                hostDisplayName: "mac-studio",
                debounce: .milliseconds(1),
            ),
            // Long enough that nothing in these tests is carried by the backstop tick: every
            // assertion must be satisfied by the explicit subscribe-time reconcile or a kick.
            workspaceReconcileInterval: .seconds(3600),
        )
        // What `start()` does before the listener accepts anything. Called directly because the rig
        // drives loopback links rather than a socket.
        await server.installWorkspaceDocumentForTesting()
        let (clientControl, hostControl) = LoopbackMuxLink.pair()
        let (clientData, hostData) = LoopbackMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let connectionID = host.connectionID
        await host.setHostOpenHandler { [weak server] open in
            server?.spawnMuxChannelForTesting(open, on: host, connectionID: connectionID)
        }
        await host.start()
        await client.start()
        return Rig(server: server, client: client, host: host, directory: directory)
    }

    /// Opens the workspace channel and subscribes, returning the control sub-channel and a collector
    /// already draining it.
    private func openWorkspace(
        _ rig: Rig,
        label: String = "mac-studio",
        clientKind: UInt8 = 0,
    ) async throws -> (control: MuxSubChannel, collector: FrameCollector, clientInstanceID: UUID) {
        let pair = try await rig.client.openChannel(
            sessionID: UUID(),
            lastReceivedSeq: 0,
            channelClass: MuxChannelClass.workspace.rawValue,
        )
        // Start collecting BEFORE the subscribe: the snapshot can land before this call returns.
        let collector = FrameCollector(pair.control)
        // AWAIT THE ACK BEFORE SUBSCRIBING. `channelOpen` is announced on the DATA link while
        // `subscribe` rides CONTROL, so a subscribe sent immediately can beat the host's
        // registration of the control sub-channel — the frame is then dropped and the client waits
        // forever for a snapshot that will never come. This showed up as a flake, not a failure,
        // which is exactly how an open-order race presents. The ack is the client-side contract.
        let verdict = await rig.client.awaitOpenAck(for: pair.data.channelID)
        XCTAssertTrue(verdict.accepted, "workspace channel refused")
        let clientInstanceID = UUID()
        try await pair.control.send(.workspaceRequest(
            requestSeq: 1,
            verb: WorkspaceRequestVerb.subscribe.rawValue,
            payload: WorkspaceSubscribe(
                clientInstanceID: clientInstanceID,
                clientKind: clientKind,
                label: label,
            ).encode(),
        ))
        return (pair.control, collector, clientInstanceID)
    }

    /// Drains a control sub-channel into a lock-guarded list on a background task, so tests POLL a
    /// snapshot instead of suspending on `iterator.next()`.
    ///
    /// Awaiting the iterator directly strands xctest forever the moment an expected frame does not
    /// arrive — a hung suite tells you nothing and blocks the gate, which is why the E2E rule in
    /// this repo is that every wait must be bounded.
    private final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Event] = []
        private var task: Task<Void, Never>?

        struct Event {
            var kind: UInt8
            var epoch: UUID
            var base: Int64
            var new: Int64
            var payload: Data
        }

        init(_ channel: MuxSubChannel) {
            let stream = channel.inbound
            task = Task { [weak self] in
                // The stream ends on a clean close and throws on link failure — either way the
                // collector simply stops, and the polling waits fail loudly instead of hanging.
                do {
                    for try await message in stream {
                        guard case let .workspaceEvent(kind, epoch, base, new, payload) = message else { continue }
                        self?.append(Event(kind: kind, epoch: epoch, base: base, new: new, payload: payload))
                    }
                } catch {}
            }
        }

        private func append(_ event: Event) {
            lock.lock()
            frames.append(event)
            lock.unlock()
        }

        func all() -> [Event] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }

        func events(_ kind: WorkspaceEventKind) -> [Event] {
            all().filter { $0.kind == kind.rawValue }
        }

        func stop() { task?.cancel() }
    }

    /// Polls until `predicate` holds, failing rather than hanging.
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
            try? await Task.sleep(for: .milliseconds(3))
        }
        if !predicate() { XCTFail("timed out waiting for \(what)", file: file, line: line) }
    }

    /// `XCTUnwrap` takes an autoclosure, which cannot `await` — hoisting the unwrap keeps every call
    /// site a single line.
    private func unwrapEvent(
        _ event: FrameCollector.Event?,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws -> FrameCollector.Event {
        try XCTUnwrap(event, file: file, line: line)
    }

    private func awaitEvent(
        _ collector: FrameCollector,
        kind: WorkspaceEventKind,
        atLeast count: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async -> FrameCollector.Event? {
        await expect({ collector.events(kind).count >= count }, "\(count)× \(kind)", file: file, line: line)
        let matching = collector.events(kind)
        return matching.count >= count ? matching[count - 1] : nil
    }

    /// Acks every document frame as it arrives — what a real client does, and what the host's flow
    /// control assumes. Exactly ONE frame is outstanding at a time: while an ack is pending, further
    /// updates coalesce into the pending slot, which is also what keeps every diff's declared
    /// `baseStateNum` equal to what the client actually holds. A test that acks once therefore sees
    /// one more frame and then silence, and it would look like the host had stopped publishing.
    private func startAckPump(_ control: MuxSubChannel, _ collector: FrameCollector) -> Task<Void, Never> {
        Task {
            var acked: Int64 = 0
            while !Task.isCancelled {
                let latest = collector.all().last {
                    ($0.kind == WorkspaceEventKind.snapshot.rawValue
                        || $0.kind == WorkspaceEventKind.diff.rawValue) && $0.new > acked
                }
                if let latest {
                    acked = latest.new
                    try? await control.send(.workspaceRequest(
                        requestSeq: 0,
                        verb: WorkspaceRequestVerb.ack.rawValue,
                        payload: WorkspaceStateCodec.encodeI64(acked),
                    ))
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    func testAWorkspaceOpenIsAcceptedAndYieldsASnapshot() async throws {
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        let snapshot = await awaitEvent(collector, kind: .snapshot)
        let frame = try XCTUnwrap(snapshot)
        XCTAssertEqual(frame.base, 0)
        XCTAssertGreaterThan(frame.new, 0)
        // Decodes as a document, and the epoch is this host's.
        _ = try WorkspaceStateCodec.decodeSnapshot(frame.payload)
        let document = rig.server.workspaceDocument
        let epoch = await document.epoch
        XCTAssertEqual(frame.epoch, epoch)
        await rig.server.stop()
    }

    func testAWorkspaceOpenNeverForksAPTY() async throws {
        // The invariant the routing PLACEMENT exists to protect. `listPanesForControl` enumerates
        // every pane the host owns across all three inventories; a workspace open must add none —
        // and must never touch the JOIN route or the detached-store claim that keep one shell per
        // sessionID.
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        _ = await awaitEvent(collector, kind: .snapshot)
        XCTAssertTrue(rig.server.listPanesForControl().isEmpty)
        await rig.server.stop()
    }

    /// The workspace channel has no off position. A host that finds `SLOPDESK_WORKSPACE_DOC=0` in its
    /// environment serves the document anyway: a client renders its layout FROM the document, so a
    /// refusal leaves it with a blank window and no error to explain it.
    ///
    /// The environment is the subject on purpose — there is no constructor argument left to pass, so
    /// this is the only surface the gate could come back through. Safe here because `HostServer` reads
    /// its environment once, at `init`, which the rig performs between the `setenv` and the `defer`;
    /// that is NOT a pattern to copy into a test whose subject reads the environment lazily.
    func testTheWorkspaceChannelIsServedWithTheEnvironmentSetToZero() async throws {
        setenv("SLOPDESK_WORKSPACE_DOC", "0", 1)
        defer { unsetenv("SLOPDESK_WORKSPACE_DOC") }
        let rig = await makeRig()
        let (_, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        // A snapshot, not merely a non-nil document: it proves the document was installed and served,
        // which is what a client needs before it can draw anything at all.
        let snapshot = await awaitEvent(collector, kind: .snapshot)
        XCTAssertNotNil(snapshot, "the document is served regardless of the environment")
        await rig.server.stop()
    }

    func testASecondWorkspaceChannelOnOneConnectionIsRefused() async throws {
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        _ = await awaitEvent(collector, kind: .snapshot)

        let second = try await rig.client.openChannel(
            sessionID: UUID(),
            lastReceivedSeq: 0,
            channelClass: MuxChannelClass.workspace.rawValue,
        )
        let verdict = await rig.client.awaitOpenAck(for: second.data.channelID)
        XCTAssertFalse(verdict.accepted)
        await rig.server.stop()
    }

    func testTheRosterNamesTheSubscribingDevice() async throws {
        let rig = await makeRig()
        let (_, collector, clientInstanceID) = try await openWorkspace(rig, label: "iPhone", clientKind: 1)
        defer { collector.stop() }
        let presence = try await unwrapEvent(awaitEvent(collector, kind: .presence))
        let roster = try WorkspacePresenceRoster.decode(presence.payload)
        XCTAssertEqual(roster.clients.count, 1)
        XCTAssertEqual(roster.clients.first?.clientInstanceID, clientInstanceID)
        XCTAssertEqual(roster.clients.first?.clientKind, 1)
        XCTAssertEqual(roster.clients.first?.label, "iPhone")
        // A LABEL, not a credential — it is checked nowhere and grants nothing.
        await rig.server.stop()
    }

    func testAPresenceUpdateWithAnOlderClockIsIgnored() async throws {
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        _ = await awaitEvent(collector, kind: .presence)

        // The `viewingTabID` of the most recent roster the host broadcast.
        @Sendable
        func latestViewingTab() -> UUID? {
            guard let frame = collector.events(.presence).last,
                  let roster = try? WorkspacePresenceRoster.decode(frame.payload)
            else { return nil }
            return roster.clients.first?.viewingTabID
        }
        // Every tab id that has EVER appeared in a broadcast roster.
        @Sendable
        func everBroadcastTabs() -> [UUID] {
            collector.events(.presence).compactMap {
                (try? WorkspacePresenceRoster.decode($0.payload))?.clients.first?.viewingTabID
            }
        }

        let tab = UUID()
        try await control.send(.workspaceRequest(
            requestSeq: 2,
            verb: WorkspaceRequestVerb.presence.rawValue,
            payload: WorkspacePresenceUpdate(presenceClock: 10, viewingTabID: tab, cols: 213, rows: 51).encode(),
        ))
        await expect({ latestViewingTab() == tab }, "the first presence to land")

        // An older clock must not resurrect a view this client has since left. Ignored means NO
        // broadcast at all — so the stale tab must never appear in ANY roster, and the newer update
        // that follows must still land.
        let stale = UUID()
        let newer = UUID()
        try await control.send(.workspaceRequest(
            requestSeq: 3,
            verb: WorkspaceRequestVerb.presence.rawValue,
            payload: WorkspacePresenceUpdate(presenceClock: 5, viewingTabID: stale).encode(),
        ))
        try await control.send(.workspaceRequest(
            requestSeq: 4,
            verb: WorkspaceRequestVerb.presence.rawValue,
            payload: WorkspacePresenceUpdate(presenceClock: 11, viewingTabID: newer).encode(),
        ))
        await expect({ latestViewingTab() == newer }, "the newer presence to land")
        XCTAssertFalse(everBroadcastTabs().contains(stale), "a stale clock must never be broadcast")
        await rig.server.stop()
    }

    func testAMalformedRequestIsDroppedAndTheChannelSurvives() async throws {
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        _ = await awaitEvent(collector, kind: .snapshot)

        // A truncated subscribe, an unknown verb, and a wrong-width ack. Tearing the channel down on
        // any of these would hand a peer a trivial way to blank a client's whole workspace — and
        // these bytes carry no authentication of any kind, by design.
        try await control.send(.workspaceRequest(requestSeq: 5, verb: 0, payload: Data([0x00])))
        try await control.send(.workspaceRequest(requestSeq: 6, verb: 200, payload: Data()))
        try await control.send(.workspaceRequest(requestSeq: 7, verb: 1, payload: Data([0x01])))

        // Still alive: a legitimate presence update still produces a roster.
        try await control.send(.workspaceRequest(
            requestSeq: 8,
            verb: WorkspaceRequestVerb.presence.rawValue,
            payload: WorkspacePresenceUpdate(presenceClock: 99, cols: 80, rows: 24).encode(),
        ))
        await expect({
            guard let frame = collector.events(.presence).last,
                  let roster = try? WorkspacePresenceRoster.decode(frame.payload) else { return false }
            return roster.clients.first?.cols == 80
        }, "a roster after the malformed burst")
        await rig.server.stop()
    }

    /// An op byte this build does not know gets a definite answer, not silence — the client rolls
    /// its optimistic patch back at once rather than waiting out a timeout.
    func testAnUnknownOpIsAnsweredRatherThanIgnored() async throws {
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        _ = await awaitEvent(collector, kind: .snapshot)

        let intentID = UUID()
        try await control.send(.workspaceRequest(
            requestSeq: 9,
            verb: WorkspaceRequestVerb.intent.rawValue,
            payload: WorkspaceIntent(intentID: intentID, op: 250, args: Data()).encode(),
        ))

        let result = try await unwrapEvent(awaitEvent(collector, kind: .intentResult))
        let decoded = try WorkspaceIntentResult.decode(result.payload)
        XCTAssertEqual(decoded.intentID, intentID)
        XCTAssertEqual(decoded.status, WorkspaceIntentStatus.unknownOp.rawValue)
        await rig.server.stop()
    }

    /// The round trip the whole phase is for: a client asks, the host decides, and the CHANGE comes
    /// back to every subscriber as an ordinary diff — not as a reply only the asker sees.
    func testAnIntentIsAnsweredAndTheChangeArrivesAsADiff() async throws {
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        let snapshot = try await unwrapEvent(awaitEvent(collector, kind: .snapshot))
        let before = try WorkspaceStateCodec.decodeSnapshot(snapshot.payload)
        let tabID = try XCTUnwrap(before.topology?.tree.sessions.first?.tabs.first?.id)

        let pump = startAckPump(control, collector)
        defer { pump.cancel() }

        let intentID = UUID()
        try await control.send(.workspaceRequest(
            requestSeq: 9,
            verb: WorkspaceRequestVerb.intent.rawValue,
            payload: WorkspaceIntent(
                intentID: intentID,
                op: WorkspaceIntentOp.renameTab.rawValue,
                args: WorkspaceIntentArgs.encode(id: tabID.raw, name: "build"),
            ).encode(),
        ))

        let result = try await unwrapEvent(awaitEvent(collector, kind: .intentResult))
        XCTAssertEqual(
            try WorkspaceIntentResult.decode(result.payload).status,
            WorkspaceIntentStatus.applied.rawValue,
        )
        await expect({
            guard let frame = collector.events(.diff).last,
                  let diff = try? WorkspaceStateCodec.decodeDiff(frame.payload) else { return false }
            return diff.sets.contains {
                $0.key == WorkspaceKey(.tab, tabID.raw, WorkspaceTabField.title)
                    && WorkspaceStateCodec.decodeString($0.value) == "build"
            }
        }, "the rename arrives as a diff every subscriber gets")
        await rig.server.stop()
    }

    /// A host with no file publishes a real workspace on the very first snapshot. Once client-side
    /// tree persistence is gone this IS the cold start — a blank first frame would dead-end it.
    func testTheFirstSnapshotAlreadyCarriesAWorkspace() async throws {
        let rig = await makeRig()
        let (_, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        let snapshot = try await unwrapEvent(awaitEvent(collector, kind: .snapshot))

        let topology = try XCTUnwrap(try WorkspaceStateCodec.decodeSnapshot(snapshot.payload).topology)
        XCTAssertEqual(topology.tree.sessions.count, 1)
        XCTAssertEqual(topology.tree.allPaneIDs().count, 1)
        XCTAssertEqual(topology.hostDisplayName, "mac-studio")
        await rig.server.stop()
    }

    /// An applied intent reaches DISK, so the layout survives a daemon restart. The sink fires on the
    /// topology half only — a liveness tick must not rewrite the file for a host nobody is using.
    func testAnAppliedIntentIsPersisted() async throws {
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        let snapshot = try await unwrapEvent(awaitEvent(collector, kind: .snapshot))
        let tabID = try XCTUnwrap(
            try WorkspaceStateCodec.decodeSnapshot(snapshot.payload).topology?.tree.sessions.first?.tabs.first?.id,
        )

        try await control.send(.workspaceRequest(
            requestSeq: 9,
            verb: WorkspaceRequestVerb.intent.rawValue,
            payload: WorkspaceIntent(
                intentID: UUID(),
                op: WorkspaceIntentOp.renameTab.rawValue,
                args: WorkspaceIntentArgs.encode(id: tabID.raw, name: "persisted"),
            ).encode(),
        ))
        _ = await awaitEvent(collector, kind: .intentResult)
        await rig.server.workspaceStore?.flush()

        let reloaded = HostWorkspaceStore(
            fileURL: rig.directory.appendingPathComponent("workspace-state.json"),
            hostDisplayName: "mac-studio",
        )
        let restored = await reloaded.load()
        XCTAssertEqual(
            restored.string(WorkspaceKey(.tab, tabID.raw, WorkspaceTabField.title)), "persisted",
        )
        await rig.server.stop()
    }

    /// The bootstrap is a bootstrap, not a migration. A host that has already written a workspace
    /// refuses an upload — and the loser is TOLD, because its tree is the only copy of a layout
    /// somebody built.
    func testAdoptIsRefusedOnceTheHostHasWrittenAWorkspace() async throws {
        let rig = await makeRig()
        let (control, collector, _) = try await openWorkspace(rig)
        defer { collector.stop() }
        let snapshot = try await unwrapEvent(awaitEvent(collector, kind: .snapshot))
        let tabID = try XCTUnwrap(
            try WorkspaceStateCodec.decodeSnapshot(snapshot.payload).topology?.tree.sessions.first?.tabs.first?.id,
        )
        // Any accepted intent takes ownership of this workspace.
        try await control.send(.workspaceRequest(
            requestSeq: 9,
            verb: WorkspaceRequestVerb.intent.rawValue,
            payload: WorkspaceIntent(
                intentID: UUID(),
                op: WorkspaceIntentOp.renameTab.rawValue,
                args: WorkspaceIntentArgs.encode(id: tabID.raw, name: "mine"),
            ).encode(),
        ))
        _ = await awaitEvent(collector, kind: .intentResult)

        var uploaded = HostWorkspaceState()
        uploaded.write(topology: WorkspaceTopology(tree: .defaultWorkspace()))
        let adoptID = UUID()
        try await control.send(.workspaceRequest(
            requestSeq: 10,
            verb: WorkspaceRequestVerb.intent.rawValue,
            payload: WorkspaceIntent(
                intentID: adoptID,
                op: WorkspaceIntentOp.adoptWorkspace.rawValue,
                args: WorkspaceStateCodec.encodeSnapshot(uploaded),
            ).encode(),
        ))

        await expect({
            guard let frame = collector.events(.intentResult).last,
                  let decoded = try? WorkspaceIntentResult.decode(frame.payload) else { return false }
            return decoded.intentID == adoptID
                && decoded.status == WorkspaceIntentStatus.rejectedStale.rawValue
        }, "the second workspace is refused, not merged")
        await rig.server.stop()
    }

    func testAProjectGitSummaryReachesTheDocumentAsTheTypeThirtyFiveBody() async throws {
        let rig = await makeRig()
        let document = rig.server.workspaceDocument
        let status = WireMessage.ProjectGitStatus(
            repoRoot: "/repo",
            branch: "main",
            ahead: 1,
            behind: 0,
            stashCount: 0,
            staged: 2,
            modified: 3,
            untracked: 4,
            conflicted: 0,
            changedCount: 9,
        )
        let id = rig.server.projectObjectID(forKey: status.repoRoot)
        await document.setProject(
            id: id,
            key: status.repoRoot,
            gitSummary: HostServer.wireBody(of: .projectGitStatus(status)),
        )
        let state = await document.snapshot
        let body = try XCTUnwrap(state[WorkspaceKey(.project, id, WorkspaceProjectField.gitSummary)])
        // The client needs no new codec: prefix the type tag and the existing decoder reads it.
        let round = try WireMessage.decode(payload: Data([35]) + body)
        guard case let .projectGitStatus(decoded) = round else {
            XCTFail("expected projectGitStatus, got \(round)")
            return
        }
        XCTAssertEqual(decoded.branch, "main")
        XCTAssertEqual(decoded.modified, 3)
        // The id is STABLE across lookups for the same key.
        XCTAssertEqual(rig.server.projectObjectID(forKey: "/repo"), id)
        await rig.server.stop()
    }
}
