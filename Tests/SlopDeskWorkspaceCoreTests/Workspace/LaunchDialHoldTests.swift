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
        let pipe: PipeChannel
        let client: WorkspaceChannelClient
        let restored: TreeWorkspace
        let acceptOpen: (Bool) -> Void
    }

    private let hostEpoch = UUID(uuidString: "F00DF00D-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!

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
            liveModel: .tree,
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
    private func makeRig(
        restored: TreeWorkspace? = nil,
        autoAccept: Bool? = true,
    ) -> Rig {
        let tree = restored ?? clientTree()
        let dials = Dials()
        let store = makeStore(tree, dials: dials)
        let pipe = PipeChannel()
        let verdict = VerdictBox()
        if let autoAccept { verdict.set(autoAccept) }
        let client = WorkspaceChannelClient(
            box: store.workspaceMirror,
            clientKind: .macOS,
            label: "mac-studio",
            open: {
                WorkspaceChannelClient.Handle(
                    channelID: 4,
                    control: pipe,
                    awaitAccepted: { await verdict.value },
                )
            },
            close: { _ in },
        )
        store.attachWorkspaceChannel(client)
        client.start()
        return Rig(
            store: store, dials: dials, pipe: pipe, client: client, restored: tree,
            acceptOpen: { verdict.set($0) },
        )
    }

    /// The host's first frame: its own document, under its own epoch.
    private func hostSnapshot(_ tree: TreeWorkspace, stateNum: Int64 = 1) -> WireMessage {
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: tree.normalized()))
        return .workspaceEvent(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: hostEpoch,
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
            now: Date().timeIntervalSince1970 + HostWorkspaceMirror.pendingTimeout,
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
    /// it (`check-macos.sh --connect`, `check-video.sh`) dial exactly when they always did.
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

    /// A reconnect is not a launch. The offer is spent at the first connect, so the re-subscribe that
    /// follows a wifi flap must not park every pane behind a second round trip.
    func testAReconnectIsNotHeld() async throws {
        let rig = makeRig()
        let intentID = await offerLaunchAdopt(rig, hostTree: .defaultWorkspace())
        let adopt = try XCTUnwrap(intentID)
        rig.pipe.deliver(intentResult(adopt, .applied))
        rig.pipe.deliver(hostDiff(to: rig.restored, base: 1, new: 2))
        await expect("the launch to settle") { rig.store.panesMayDial }

        rig.client.stop()
        rig.client.start()

        XCTAssertTrue(rig.store.panesMayDial, "the offer is spent; a new subscription holds nothing")
    }
}
