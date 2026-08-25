import Foundation
import SlopDeskClient
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// A pane does not open a PTY under an id the host has not confirmed.
///
/// The optimistic overlay exists so the layout a client restored from disk is on screen in the first
/// frame. SHOWING a pane and OPENING a shell for it are different acts, and only the first is safe
/// before the document answers: `HostServer` spawns a fresh PTY for ANY unknown non-zero session id
/// (PATH B), so a client that dials its restored ids at a host holding a different set gets a shell
/// per stale id — and then the refused `adoptWorkspace` replaces the layout with host truth and
/// abandons every one of them.
///
/// Measured on hardware before the hold, one hostd and two launches with divergent ids:
///
///     client renders 11111111 22222222 33333333   (host truth)
///     …having dialled 5C95FF8D 6573D268 71673628  (its own restore)
///     -> 6 shells spawned for 3 panes
///
/// So the property is: from the moment this launch's `adoptWorkspace` goes out until the host
/// answers it, no pane dials. The window is one round trip wide and it closes on the answer, whatever
/// the answer is.
///
/// Driven over a REAL ``WorkspaceChannelClient`` on an in-memory control channel — open → ack →
/// subscribe → snapshot → intent → result — because the sequence under test IS that loop. The
/// loopback document answers on the calling line and so has no unanswered window at all.
@MainActor
final class LaunchDialHoldTests: XCTestCase {
    // MARK: - Doubles

    /// An in-memory PTY transport that resolves `connect()` with no networking (the
    /// `RedialDetachedPaneTests` shape).
    private actor ImmediateTransport: ClientTransporting {
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation

        init() {
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func connect(
            host _: String,
            port _: UInt16,
            resume _: UUID,
            lastReceivedSeq _: Int64,
            handshakeTimeout _: Duration,
        ) async {
            await Task.yield()
            _sessionID = UUID()
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }

    /// Which pane ids actually opened a channel, in order — the headless twin of the host log's
    /// `attached for pane <uuid>` lines, which is what the hardware repro counts.
    private final class Dials: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [PaneID] = []
        var dialled: [PaneID] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }

        func makeTransport(for pane: PaneID) -> ImmediateTransport {
            lock.lock()
            ids.append(pane)
            lock.unlock()
            return ImmediateTransport()
        }
    }

    /// The workspace channel's control ends, newest last. One per `open`, because an
    /// `AsyncThrowingStream` is consumed by the run that iterates it: a re-subscribe that reused the
    /// previous pipe would deliver to nobody, and the host-switch tests are entirely about what the
    /// SECOND subscription sees.
    private final class PipeBox: @unchecked Sendable {
        private let lock = NSLock()
        /// The first end is minted up front, so a test can play the host before the run loop has got
        /// as far as calling `open`.
        private var pipes: [PipeChannel] = [PipeChannel()]
        private var handedOut = 0

        /// Hands the next subscription its own control end.
        func open() -> PipeChannel {
            lock.lock()
            defer { lock.unlock() }
            handedOut += 1
            if handedOut > pipes.count { pipes.append(PipeChannel()) }
            return pipes[handedOut - 1]
        }

        /// The end the newest subscription talks through.
        var current: PipeChannel {
            lock.lock()
            defer { lock.unlock() }
            return pipes[max(handedOut - 1, 0)]
        }

        /// How many subscriptions have been opened — 2 once a re-subscribe has landed.
        var openCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return handedOut
        }
    }

    /// The workspace channel's control end, held by the test so it can play the host.
    private final class PipeChannel: MessageChannel, @unchecked Sendable {
        let channel: Channel = .control
        let inbound: AsyncThrowingStream<WireMessage, Error>
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        private let lock = NSLock()
        private var sent: [WireMessage] = []

        init() {
            (inbound, continuation) = AsyncThrowingStream.makeStream(of: WireMessage.self)
        }

        /// Non-throwing on purpose: this pipe never fails a write, and the launch hold's whole
        /// subject is what happens when the host DOES answer. `WorkspaceChannelClientTests` owns the
        /// failing-write cases.
        func send(_ message: WireMessage) async {
            await Task.yield()
            // A synchronous helper: `NSLock` is unavailable from an async context, and holding one
            // across a suspension is the mistake that ban exists to catch.
            record(message)
        }

        private func record(_ message: WireMessage) {
            lock.lock()
            sent.append(message)
            lock.unlock()
        }

        func deliver(_ message: WireMessage) { continuation.yield(message) }

        /// Ends this subscription the way a DROPPED LINK does: the inbound stream finishes and the
        /// run loop unwinds to `.closed` on its own.
        ///
        /// Deliberately not ``WorkspaceChannelClient/stop()``. A stop also resets the mirror, and the
        /// whole question a reconnect asks is what the fan-out can see — so a test that reached for
        /// the stop would be asserting about an empty document rather than about the drop.
        func drop() { continuation.finish() }

        /// Every intent this client has put on the wire, decoded.
        var intents: [WorkspaceIntent] {
            lock.lock()
            let messages = sent
            lock.unlock()
            return messages.compactMap {
                guard case let .workspaceRequest(_, verb, payload) = $0,
                      verb == WorkspaceRequestVerb.intent.rawValue else { return nil }
                return try? WorkspaceIntent.decode(payload)
            }
        }
    }

    /// A verdict that can be supplied after a waiter has already suspended on it.
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

    // MARK: - Rig

    private struct Rig {
        let store: WorkspaceStore
        let dials: Dials
        let pipes: PipeBox
        let client: WorkspaceChannelClient
        let restored: TreeWorkspace
        let acceptOpen: (Bool) -> Void

        /// The control end of the subscription that is live now.
        var pipe: PipeChannel { pipes.current }
    }

    private let hostEpoch = UUID(uuidString: "F00DF00D-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
    /// A second machine's document identity — a different workspace, not a new version of the first.
    private static let hostBEpoch = UUID(uuidString: "B0B0B0B0-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!

    /// The machine a run starts on, and the one the user then points it at. Same ports, different
    /// address: ``DevicePreferences/hostKey(for:)`` is `host:port`, which is the only host identity
    /// that exists before a connect.
    private static let hostA = ConnectionTarget(host: "10.0.0.1", port: 47420, mediaPort: 47421, cursorPort: 47422)
    private static let hostB = ConnectionTarget(host: "10.0.0.2", port: 47420, mediaPort: 47421, cursorPort: 47422)

    /// Three single-leaf tabs, the `WorkspaceLaunchAdoptTests` shape — one restored pane per tab, so
    /// a dial per pane is a shell per pane.
    private func clientTree(titles: [String] = ["alpha", "beta", "gamma"]) -> TreeWorkspace {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for title in titles {
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: title)
            tabs.append(Tab(title: title, root: .leaf(pane), activePane: pane))
        }
        let session = Session(name: "restored", tabs: tabs, activeTabIndex: 0, specs: specs)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    /// A store whose leaves mint REAL ``LivePaneSession``s over `dials`' transport — the seam that
    /// actually opens a channel. A `FakePaneSession` store cannot see this property at all.
    private func makeStore(_ tree: TreeWorkspace, dials: Dials) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: tree,
            makeSession: { seed in
                LivePaneSession.make(
                    paneID: seed.id,
                    spec: seed.spec,
                    spawnCwd: seed.spawnCwd,
                    makeClient: { _ in SlopDeskClient(makeTransport: { dials.makeTransport(for: seed.id) }) },
                    makeInspector: { _ in nil },
                    target: { .default },
                )
            },
        )
    }

    /// A launch: the layout restored from disk, a channel installed and started, and nothing back
    /// from the host yet.
    ///
    /// - Parameter autoAccept: `nil` withholds the `channelOpenAck` verdict, which is the state a
    ///   cold launch spends its first round trips in.
    /// - Parameter connectedTo: the target to commit before the channel is installed — the app shell
    ///   stamps one from the MRU before anything dials. `nil` leaves the store with no host identity,
    ///   which is every pre-existing case in this file.
    private func makeRig(
        restored: TreeWorkspace? = nil,
        autoAccept: Bool? = true,
        connectedTo target: ConnectionTarget? = nil,
    ) -> Rig {
        let tree = restored ?? clientTree()
        let dials = Dials()
        let store = makeStore(tree, dials: dials)
        if let target { store.commitConnectionTarget(target) }
        let pipes = PipeBox()
        let verdict = VerdictBox()
        if let autoAccept { verdict.set(autoAccept) }
        let client = WorkspaceChannelClient(
            box: store.workspaceMirror,
            clientKind: .macOS,
            label: "mac-studio",
            open: {
                WorkspaceChannelClient.Handle(
                    channelID: 4,
                    control: pipes.open(),
                    awaitAccepted: { await verdict.value },
                )
            },
            close: { _ in },
        )
        store.attachWorkspaceChannel(client)
        client.start()
        return Rig(
            store: store, dials: dials, pipes: pipes, client: client, restored: tree,
            acceptOpen: { verdict.set($0) },
        )
    }

    /// The host's first frame: its own document, under its own epoch.
    private func hostSnapshot(_ tree: TreeWorkspace, stateNum: Int64 = 1, epoch: UUID? = nil) -> WireMessage {
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: tree.normalized()))
        return .workspaceEvent(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: epoch ?? hostEpoch,
            baseStateNum: 0,
            newStateNum: stateNum,
            payload: WorkspaceStateCodec.encodeSnapshot(state),
        )
    }

    /// The host's answer to one intent.
    private func intentResult(_ intentID: UUID, _ status: WorkspaceIntentStatus) -> WireMessage {
        .workspaceEvent(
            kind: WorkspaceEventKind.intentResult.rawValue,
            epoch: hostEpoch,
            baseStateNum: 0,
            newStateNum: 0,
            payload: WorkspaceIntentResult(intentID: intentID, status: status).encode(),
        )
    }

    /// The document frame an ACCEPTED adopt produces: host truth is now the client's own layout.
    private func hostDiff(to tree: TreeWorkspace, base: Int64, new: Int64) -> WireMessage {
        var next = HostWorkspaceState()
        next.write(topology: WorkspaceTopology(tree: tree.normalized()))
        return .workspaceEvent(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: hostEpoch,
            baseStateNum: base,
            newStateNum: new,
            payload: WorkspaceStateCodec.encodeDiff(next.diff(from: HostWorkspaceState())),
        )
    }

    private func megaYield() async { for _ in 0..<80 { await Task.yield() } }

    /// Polls until `condition` holds, then returns. Fails the test on timeout rather than stranding
    /// the strand (DECISIONS Phase-4 ruling 8).
    private func expect(
        _ what: String,
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// Runs the launch to the point where the offer is on the wire and unanswered, and hands back
    /// its intent id.
    private func offerLaunchAdopt(_ rig: Rig, hostTree: TreeWorkspace) async -> UUID? {
        rig.pipe.deliver(hostSnapshot(hostTree))
        await expect("the launch adopt to reach the wire") {
            rig.pipe.intents.contains { $0.op == WorkspaceIntentOp.adoptWorkspace.rawValue }
        }
        return rig.pipe.intents.first { $0.op == WorkspaceIntentOp.adoptWorkspace.rawValue }?.intentID
    }

    // MARK: - The hold

    /// RED before the hold: `redialDisconnectedPanes()` dialled all three restored panes while the
    /// subscription was still opening, so the host had spawned three shells before it ever said which
    /// panes exist.
    func testNoPaneDialsWhileTheSubscriptionIsStillOpening() async {
        let rig = makeRig(autoAccept: nil)

        XCTAssertFalse(rig.store.panesMayDial, "the layout on screen is this client's own restore")
        rig.store.redialDisconnectedPanes()
        await megaYield()

        XCTAssertEqual(
            rig.dials.dialled, [],
            "a pane whose id the host has not confirmed must not open a channel — the host spawns a "
                + "fresh PTY for every unknown session id",
        )
    }

    /// …and it keeps holding across the offer itself. The optimistic patch puts the restored layout
    /// back on screen the instant `adoptWorkspace` goes out, and THAT is the window the hardware
    /// churn lives in: the panes look real, the verdict is a round trip away.
    func testNoPaneDialsWhileTheOfferIsUnanswered() async {
        let rig = makeRig()
        let intentID = await offerLaunchAdopt(rig, hostTree: clientTree(titles: ["host"]))
        XCTAssertNotNil(intentID)

        rig.store.redialDisconnectedPanes()
        await megaYield()

        XCTAssertFalse(rig.store.panesMayDial, "the offer is on the wire and undecided")
        XCTAssertEqual(rig.dials.dialled, [], "nothing dials against a prediction")
    }

    /// The hardware repro, headless: a returning client whose `workspace.json` names panes the host
    /// has never heard of (a client-side schema reset, a second host, a layout restored from a
    /// backup). RED before the hold at SIX dials — three stale, three real.
    func testADivergentHostNeverSeesTheIdsThisClientRestored() async throws {
        let hostTree = clientTree(titles: ["host one", "host two", "host three"])
        let rig = makeRig()
        let intentID = await offerLaunchAdopt(rig, hostTree: hostTree)

        // The host already has a workspace, so the offer is refused and its tree stands.
        let adopt = try XCTUnwrap(intentID)
        rig.pipe.deliver(intentResult(adopt, .rejectedStale))
        await expect("the hold to release") { rig.store.panesMayDial }
        await megaYield()

        XCTAssertEqual(
            Set(rig.store.tree.allPaneIDs()), Set(hostTree.allPaneIDs()),
            "the client projects host truth",
        )
        XCTAssertEqual(
            Set(rig.dials.dialled), Set(hostTree.allPaneIDs()),
            "only host truth's panes were ever dialled",
        )
        XCTAssertEqual(
            rig.dials.dialled.count, hostTree.allPaneIDs().count,
            "…each exactly once — a second dial for a pane is a second shell",
        )
        for pane in rig.restored.allPaneIDs() {
            XCTAssertFalse(
                rig.dials.dialled.contains(pane),
                "restored pane \(pane.raw) was never put on the wire",
            )
        }
    }

    /// A PRISTINE host takes the layout, and then every restored pane dials — under its own id, once.
    /// The hold delays the dial by one answer; it must not lose it.
    func testThePanesDialWhenAPristineHostTakesTheLayout() async throws {
        let rig = makeRig()
        let intentID = await offerLaunchAdopt(rig, hostTree: .defaultWorkspace())
        XCTAssertEqual(rig.dials.dialled, [], "precondition: held")

        let adopt = try XCTUnwrap(intentID)
        rig.pipe.deliver(intentResult(adopt, .applied))
        rig.pipe.deliver(hostDiff(to: rig.restored, base: 1, new: 2))
        await expect("the hold to release") { rig.store.panesMayDial }
        await megaYield()

        XCTAssertEqual(
            Set(rig.dials.dialled), Set(rig.restored.allPaneIDs()),
            "the offer was accepted, so these ids ARE host truth and every one of them dials",
        )
        XCTAssertEqual(rig.dials.dialled.count, 3, "…exactly once each")
    }

    /// The release is a STORE-level fan-out, not something only a mounted SwiftUI leaf can do: the
    /// panes come up with no view in the process at all.
    func testTheReleaseDialsWithNoViewInTheLoop() async throws {
        let rig = makeRig()
        let intentID = await offerLaunchAdopt(rig, hostTree: .defaultWorkspace())

        // No `redialDisconnectedPanes()` anywhere — the verdict alone has to be enough.
        let adopt = try XCTUnwrap(intentID)
        rig.pipe.deliver(intentResult(adopt, .applied))
        rig.pipe.deliver(hostDiff(to: rig.restored, base: 1, new: 2))
        await expect("every restored pane to dial") {
            Set(rig.dials.dialled) == Set(rig.restored.allPaneIDs())
        }
    }

    /// A host that never answers releases the hold on the pending backstop rather than never. A
    /// launch that hangs must degrade to the OLD behaviour, not to a window of dead panes.
    ///
    /// What comes up then is HOST TRUTH: dropping the unanswered patch takes the restored layout off
    /// screen with it, so the panes that dial are the host's own — never the ids nobody confirmed.
    func testAnUnansweredOfferReleasesOnTheBackstop() async {
        let hostTree = clientTree(titles: ["host only"])
        let rig = makeRig()
        _ = await offerLaunchAdopt(rig, hostTree: hostTree)
        XCTAssertFalse(rig.store.panesMayDial, "precondition: waiting on a verdict")

        // The sweep the channel arms for exactly this case, run on the test's own clock.
        rig.store.workspaceMirror.expirePending(
            now: Date().timeIntervalSince1970 + WorkspaceMirrorBox.pendingTimeout,
        )
        await expect("the backstop to release the hold") { rig.store.panesMayDial }
        await megaYield()

        XCTAssertEqual(Set(rig.dials.dialled), Set(hostTree.allPaneIDs()))
        XCTAssertEqual(rig.dials.dialled.count, 1)
    }

    // MARK: - Everything that has nothing to wait for

    /// A store with no workspace channel is headless — nothing is coming, so nothing is held.
    func testAStoreWithNoChannelIsNeverHeld() {
        let store = makeStore(clientTree(), dials: Dials())
        XCTAssertTrue(store.panesMayDial)
    }

    /// The in-process loopback seam adopts the mirror this store SEEDED, so its document already is
    /// this tree. Holding for it would hold forever — every headless harness and every test that
    /// installs one dials through this.
    func testTheLoopbackSeamIsNeverHeld() {
        let store = makeStore(clientTree(), dials: Dials())
        store.attachLoopbackWorkspaceDocument()
        XCTAssertNotNil(store.pendingLaunchAdopt, "precondition: the offer is still armed")
        XCTAssertTrue(store.panesMayDial)
    }

    /// A host that does not serve the workspace class answers `refused`. That is a definite answer,
    /// so the hold lifts — otherwise a default-ON client against a default-OFF host would show a
    /// layout whose panes never connect, which is strictly worse than the churn.
    func testARefusedChannelReleasesTheHold() async {
        let rig = makeRig(autoAccept: nil)
        XCTAssertFalse(rig.store.panesMayDial, "precondition: held while the open is in flight")

        rig.acceptOpen(false)
        await expect("the refusal to settle") { rig.client.state == .refused }
        await megaYield()

        XCTAssertTrue(rig.store.panesMayDial, "a refusal is an answer")
        XCTAssertEqual(
            Set(rig.dials.dialled), Set(rig.restored.allPaneIDs()),
            "…and the panes it was holding come up",
        )
    }

    /// The AUTOMATION bootstrap publishes its own shape and clears the offer, so the gates that ride
    /// it (`slopdesk-guigate macos --connect`, `slopdesk-guigate video`) dial exactly when they always did.
    func testTheAutomationBootstrapIsNeverHeld() {
        let dials = Dials()
        let store = makeStore(clientTree(), dials: dials)
        store.bootstrapFromEnvironment([
            "SLOPDESK_AUTOCONNECT_HOST": "127.0.0.1",
            "SLOPDESK_AUTOCONNECT_PORT": "47420",
        ])
        XCTAssertNil(store.pendingLaunchAdopt, "precondition: the bootstrap owns this launch's layout")
        XCTAssertTrue(store.panesMayDial)
    }

    /// A reconnect to the SAME host is not a launch. The offer is spent at the first connect and the
    /// panes on screen came from THIS host's own last frame, so their ids are confirmed — parking
    /// them behind a second round trip after a wifi flap would be latency for nothing.
    func testAReconnectToTheSameHostIsNotHeld() async throws {
        let rig = makeRig(connectedTo: Self.hostA)
        let intentID = await offerLaunchAdopt(rig, hostTree: .defaultWorkspace())
        let adopt = try XCTUnwrap(intentID)
        rig.pipe.deliver(intentResult(adopt, .applied))
        rig.pipe.deliver(hostDiff(to: rig.restored, base: 1, new: 2))
        await expect("the launch to settle") { rig.store.panesMayDial }

        // A re-establish re-stamps the very same target before it reports up.
        rig.store.commitConnectionTarget(Self.hostA)
        rig.client.stop()
        rig.client.start()

        XCTAssertTrue(rig.store.panesMayDial, "the same host confirmed these ids; nothing is being waited for")
    }

    // MARK: - The same property, one host later

    /// A run that has settled at host A: A refused this launch's offer, A's own layout is what is on
    /// screen, and each of its panes holds exactly one open channel.
    private func settledAtHostA(_ hostATree: TreeWorkspace) async throws -> Rig {
        let rig = makeRig(connectedTo: Self.hostA)
        let offered = await offerLaunchAdopt(rig, hostTree: hostATree)
        let adopt = try XCTUnwrap(offered)
        rig.pipe.deliver(intentResult(adopt, .rejectedStale))
        await expect("host A's own panes to come up") {
            Set(rig.dials.dialled) == Set(hostATree.allPaneIDs())
        }
        XCTAssertEqual(
            rig.dials.dialled.count, hostATree.allPaneIDs().count,
            "precondition: one channel per pane, all of them host A's",
        )
        return rig
    }

    /// A link going away: every pane channel goes down with it (a deliberate close, so no per-pane
    /// reconnect campaign follows and the only thing that can dial is the store's own fan-out), and
    /// the workspace subscription unwinds to `.closed` on its own.
    ///
    /// The subscription half is not decoration. It is the state the app is ACTUALLY in when the next
    /// target is committed — the shared connection is torn down before the new endpoint is stamped —
    /// and a rig that left the channel `.live` would be asking the gate an easier question than
    /// hardware ever does.
    private func dropTheLink(_ rig: Rig) async {
        for id in rig.store.tree.allPaneIDs() {
            await (rig.store.handle(for: id) as? LivePaneSession)?.connection?.disconnect()
        }
        rig.pipe.drop()
        await expect("the subscription to unwind") { rig.client.state == .closed }
    }

    /// The user points the app at a SECOND machine inside one app run.
    ///
    /// The old link goes away, the new target is committed — which ``AppConnection`` does BEFORE the
    /// connection reports up — and the establish fan-out runs the moment it does.
    private func switchToHostB(
        _ rig: Rig,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        await dropTheLink(rig)
        rig.store.commitConnectionTarget(Self.hostB)
        // The fan-out has to have panes to iterate for the HOLD to be what stops them. `tree` is a
        // pure projection of the mirror, so an empty document at this instant would make every
        // "nothing dialled" assertion below true for a reason that has nothing to do with
        // provenance — and the gate could then be deleted outright with every one of them still
        // green.
        XCTAssertFalse(
            rig.store.tree.allPaneIDs().isEmpty,
            "precondition: host A's layout is still on screen when the fan-out runs",
            file: file, line: line,
        )
        rig.store.handleConnectionEstablished()
    }

    /// The headline, one host over. The tree on screen is host A's document; host B has published
    /// nothing. Every pane id in that tree is an id B has never heard of, so dialling them is the
    /// launch churn exactly — `HostServer` spawns a fresh PTY per unknown session id, and B's own
    /// document replaces the layout a round trip later and abandons every one of them.
    ///
    /// RED before the fix at six channels for three panes: the hold is spent with the launch, so the
    /// re-establish fan-out dials A's ids straight into B.
    func testNoPaneDialsThePreviousHostsIdsAtANewHost() async throws {
        let hostATree = clientTree(titles: ["a one", "a two", "a three"])
        let rig = try await settledAtHostA(hostATree)

        await switchToHostB(rig)
        await megaYield()

        XCTAssertFalse(
            rig.store.panesMayDial,
            "the layout on screen is host A's; host B has confirmed none of it",
        )
        XCTAssertEqual(
            rig.dials.dialled.count, hostATree.allPaneIDs().count,
            "no pane opened a second channel — a dial at host B under host A's id is a shell nobody attaches to",
        )
    }

    /// …and it releases on host B's own first frame, with B's panes — never A's — dialling.
    func testTheHostSwitchHoldReleasesOnTheNewHostsDocument() async throws {
        let hostATree = clientTree(titles: ["a one", "a two", "a three"])
        let hostBTree = clientTree(titles: ["b one", "b two"])
        let rig = try await settledAtHostA(hostATree)

        await switchToHostB(rig)
        await expect("the re-subscribe to reach host B") { rig.pipes.openCount == 2 }
        rig.pipe.deliver(hostSnapshot(hostBTree, stateNum: 9, epoch: Self.hostBEpoch))

        await expect("host B's document to release the hold") { rig.store.panesMayDial }
        await expect("host B's own panes to dial") {
            Set(hostBTree.allPaneIDs()).isSubset(of: Set(rig.dials.dialled))
        }
        await megaYield()

        XCTAssertEqual(
            Set(rig.store.tree.allPaneIDs()), Set(hostBTree.allPaneIDs()),
            "the client projects host B's truth",
        )
        XCTAssertEqual(
            rig.dials.dialled.count, hostATree.allPaneIDs().count + hostBTree.allPaneIDs().count,
            "…and every channel ever opened was named by the host it was opened at",
        )
    }

    /// A host that ACCEPTS the workspace class and then publishes nothing must not hold the panes for
    /// the life of the process. Nothing else bounds this arm: `.live` is published only when a frame
    /// folds, so a subscription that never gets one sits in `.opening` forever. A hold with no
    /// release is worse than the churn it prevents, so it degrades to dialling.
    func testTheHostSwitchHoldReleasesOnTheBackstop() async throws {
        let hostATree = clientTree(titles: ["a one", "a two", "a three"])
        let rig = try await settledAtHostA(hostATree)
        rig.store.paneDialHoldBackstop = .milliseconds(50)

        await switchToHostB(rig)
        XCTAssertFalse(rig.store.panesMayDial, "precondition: waiting on host B's first frame")

        await expect("the backstop to release the hold") { rig.store.panesMayDial }
    }

    // MARK: - The reconnect fan-out

    /// The reconnect ``AppConnection`` drives: the SAME target is re-stamped, then the establish
    /// hook runs.
    private func reconnectToHostA(_ rig: Rig) {
        rig.store.commitConnectionTarget(Self.hostA)
        rig.store.handleConnectionEstablished()
    }

    /// The headline of this section: a reconnect to the same machine brings the panes back.
    ///
    /// ``WorkspaceStore/redialDisconnectedPanes()`` is the ONLY thing that can. The leaf's
    /// connect-on-appear `.task` does not re-fire under keep-all-mounted — the live id never moved —
    /// so a fan-out that dials nothing leaves three dead terminals behind a green "Connected" pill,
    /// until the user hits per-pane Reconnect three times.
    ///
    /// RED at three channels for three panes when the fan-out runs AFTER the subscription is
    /// re-opened: ``WorkspaceChannelClient/stop()`` resets the mirror and ``WorkspaceStore/tree`` is
    /// a pure projection of it, so the fan-out iterates an EMPTY pane set — and the re-subscribe's
    /// own snapshot then puts the layout back on screen without dialling any of it.
    func testAReconnectToTheSameHostRedialsThePanesTheDropTookDown() async throws {
        let hostATree = clientTree(titles: ["a one", "a two", "a three"])
        let rig = try await settledAtHostA(hostATree)
        let panes = Set(hostATree.allPaneIDs())

        await dropTheLink(rig)
        await expect("every pane to be down") {
            panes.allSatisfy {
                (rig.store.handle(for: $0) as? LivePaneSession)?.connection?.status == .disconnected
            }
        }

        reconnectToHostA(rig)
        await expect("the re-subscribe to reach the host") { rig.pipes.openCount == 2 }
        rig.pipe.deliver(hostSnapshot(hostATree, stateNum: 7))
        await expect("the layout to come back") { Set(rig.store.tree.allPaneIDs()) == panes }

        await expect("every pane the drop took down to dial again") {
            rig.dials.dialled.count == 2 * panes.count
        }
        XCTAssertEqual(
            Set(rig.dials.dialled), panes,
            "…each of them host A's own id, dialled at host A — the second channel is a REATTACH",
        )
        await expect("every pane to be live again") {
            panes.allSatisfy {
                (rig.store.handle(for: $0) as? LivePaneSession)?.connection?.status == .connected
            }
        }
    }

    /// The same reconnect, one flap deeper — the case the fan-out alone cannot serve.
    ///
    /// The second establish arrives while the mirror is EMPTY: the first one re-opened the
    /// subscription, and that reset the document before this host's snapshot had answered. So there
    /// is no pane set to iterate at establish time, and the gate never moves (host A confirmed these
    /// ids before the flap, so it was open the whole way through) — nothing gives the fan-out a
    /// second chance. What does is the document itself: the first frame the ATTACHED host folds is
    /// the moment the panes are back on screen and their provenance is settled.
    func testTheReconnectFanOutSurvivesADropThatBeatsTheSnapshot() async throws {
        let hostATree = clientTree(titles: ["a one", "a two", "a three"])
        let rig = try await settledAtHostA(hostATree)
        let panes = Set(hostATree.allPaneIDs())

        await dropTheLink(rig)
        reconnectToHostA(rig)
        await expect("the re-subscribe to reach the host") { rig.pipes.openCount == 2 }

        // …and the link dies again before that subscription's snapshot lands, so the mirror the
        // NEXT establish reads is the empty one the re-open left behind.
        rig.pipe.drop()
        await expect("the second subscription to unwind") { rig.client.state == .closed }
        XCTAssertTrue(rig.store.tree.allPaneIDs().isEmpty, "precondition: the document is gone")

        reconnectToHostA(rig)
        await expect("the third subscribe to reach the host") { rig.pipes.openCount == 3 }
        rig.pipe.deliver(hostSnapshot(hostATree, stateNum: 11))

        await expect("host A's own document to redial its panes") {
            rig.dials.dialled.count == 2 * panes.count
        }
        XCTAssertEqual(Set(rig.dials.dialled), panes, "and nothing outside host A's own layout dialled")
    }

    // MARK: - What the window shows while the host says nothing

    /// The layout restored from disk stays on screen across an establish the host never answers.
    ///
    /// ``WorkspaceStore/handleConnectionEstablished()`` re-opens the subscription, and
    /// ``WorkspaceChannelClient/stop()`` forgets host truth on the way — but a COLD launch has none
    /// to forget: every entry in the mirror is this client's own seed. Resetting there empties
    /// ``WorkspaceStore/tree``, which is a pure projection, so the window the user restored goes
    /// blank. A host that then never answers — a class it does not know, a wedged daemon, a link
    /// that dies mid-subscribe — makes the blank permanent, which is the exact failure the document
    /// being unconditional exists to rule out.
    ///
    /// Shown, not dialled: the ids are still unconfirmed, so the layout is a picture until the host
    /// names it. That is the division of labour the hold was built for.
    func testTheRestoredLayoutSurvivesAnEstablishTheHostNeverAnswers() async {
        let restored = clientTree(titles: ["alpha", "beta", "gamma"])
        let rig = makeRig(restored: restored, connectedTo: Self.hostA)
        XCTAssertEqual(
            Set(rig.store.tree.allPaneIDs()), Set(restored.allPaneIDs()),
            "precondition: the restored layout is what the window is showing",
        )

        rig.store.handleConnectionEstablished()
        await expect("the re-subscribe to reach the host") { rig.pipes.openCount == 2 }

        XCTAssertEqual(
            Set(rig.store.tree.allPaneIDs()), Set(restored.allPaneIDs()),
            "the window still shows the layout this client restored",
        )
        XCTAssertTrue(rig.dials.dialled.isEmpty, "and no pane opened a PTY under an unconfirmed id")
    }
}
