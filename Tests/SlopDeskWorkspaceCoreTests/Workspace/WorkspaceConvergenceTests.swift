import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskWorkspaceCore

/// A `MessageChannel` that pipes what the host sent straight into a client mirror, acking as a real
/// client does.
///
/// The ack matters: exactly ONE frame is outstanding at a time, so a mirror that never acknowledged
/// would see one frame and then silence — which looks like the host stopped publishing but is the
/// flow control working.
private final class MirroringChannel: MessageChannel, @unchecked Sendable {
    let channel: Channel = .control

    private let lock = NSLock()
    private var _mirror = HostWorkspaceMirror()
    private var _acks: [Int64] = []

    var mirror: HostWorkspaceMirror {
        lock.lock()
        defer { lock.unlock() }
        return _mirror
    }

    /// The stateNums this client owes an ack for, taken once.
    func drainAcks() -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        let out = _acks
        _acks = []
        return out
    }

    var inbound: AsyncThrowingStream<WireMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func send(_ message: WireMessage) async {
        // A real send suspends. Yielding keeps the coalescing path honest: an update arriving WHILE
        // a frame is in flight must land rather than be swallowed by the single buffered wake.
        await Task.yield()
        guard case let .workspaceEvent(kind, epoch, base, new, payload) = message else { return }
        // Synchronous, so the lock is never held across a suspension — `NSLock` is unavailable from
        // an async context precisely to stop that.
        apply(kind: kind, epoch: epoch, base: base, new: new, payload: payload)
    }

    private func apply(kind: UInt8, epoch: UUID, base: Int64, new: Int64, payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        let outcome = _mirror.apply(
            kind: kind, epoch: epoch, baseStateNum: base, newStateNum: new, payload: payload,
        )
        if case let .applied(stateNum) = outcome { _acks.append(stateNum) }
    }
}

/// The claim the whole design rests on: **two clients watching one host converge on byte-identical
/// state**, whatever order their intents arrive in.
///
/// Everything else in this document is machinery in service of that sentence. The diff is computed
/// from what each subscriber ACKED rather than what was last sent, so a lost frame self-heals on the
/// next tick; a diff is a set of independent assignments, so duplicates and reorders are no-ops by
/// construction; and every mutation runs on one actor, so `stateNum` is monotone and the last write
/// to a cell wins by arrival rather than by a merge function nobody can reason about.
///
/// This test is the end-to-end evidence, driven through the REAL `WorkspaceChannelSession` — the
/// coalescing send task, the retained sent-state window and the acked-base diff — rather than
/// through the value layer, which `WorkspaceIntentApplierTests` already covers.
final class WorkspaceConvergenceTests: XCTestCase {
    private struct Rig {
        let document: HostWorkspaceDocument
        let clients: [MirroringChannel]
        let sessions: [WorkspaceChannelSession]
    }

    /// Pumps every outstanding ack until both mirrors are quiet, so the next intent starts from a
    /// caught-up host.
    private func settle(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            var moved = false
            for (client, session) in zip(rig.clients, rig.sessions) {
                for stateNum in client.drainAcks() {
                    moved = true
                    await session.note(ack: stateNum)
                }
            }
            let current = await rig.document.stateNum
            let caughtUp = rig.clients.allSatisfy { $0.mirror.stateNum == current }
            if caughtUp, !moved { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the clients never caught up with the host", file: file, line: line)
    }

    private func makeRig(_ topology: WorkspaceTopology) async -> Rig {
        var state = HostWorkspaceState()
        state.write(topology: topology)
        let document = HostWorkspaceDocument()
        await document.install(state: state, pristine: false)
        let clients = [MirroringChannel(), MirroringChannel()]
        var sessions: [WorkspaceChannelSession] = []
        for client in clients {
            let session = WorkspaceChannelSession(
                channel: client,
                subscribe: WorkspaceSubscribe(clientInstanceID: UUID(), clientKind: 0, label: "client"),
            )
            await document.addSubscriber(session)
            sessions.append(session)
        }
        return Rig(document: document, clients: clients, sessions: sessions)
    }

    private func fixture() -> (WorkspaceTopology, SessionID, TabID, PaneID) {
        let pane = PaneID()
        let tab = Tab(id: TabID(), title: "one", root: .leaf(pane), activePane: pane)
        let session = Session(
            id: SessionID(),
            name: "slop-desk",
            tabs: [tab],
            specs: [pane: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        return (
            WorkspaceTopology(tree: TreeWorkspace(
                sessions: [session], activeSessionID: session.id,
            )),
            session.id, tab.id, pane,
        )
    }

    // MARK: - The claim

    /// Interleaved intents from two clients, applied through the real actor and delivered through the
    /// real diff machinery, leave both mirrors byte-identical to each other AND to the host.
    func testTwoClientsInterleavingIntentsConvergeByteIdentically() async throws {
        let (topology, sessionID, tabID, paneID) = fixture()
        let rig = await makeRig(topology)
        defer { for session in rig.sessions { session.close() } }
        await settle(rig)

        let extra = PaneID()
        // Alternating clients, but both go through the one actor — which is the point: there is no
        // per-client state to diverge, only an arrival order.
        let script: [(WorkspaceIntentOp, Data)] = [
            (.splitPane, WorkspaceIntentArgs.encode(
                target: paneID.raw, axis: .horizontal, before: false, newPane: extra, spawnCwd: "/repo",
            )),
            (.renameTab, WorkspaceIntentArgs.encode(id: tabID.raw, name: "build")),
            (.renamePane, WorkspaceIntentArgs.encode(id: extra.raw, name: "logs")),
            (.setSyncInput, WorkspaceIntentArgs.encode(id: tabID.raw, flag: true)),
            (.renameSession, WorkspaceIntentArgs.encode(id: sessionID.raw, name: "renamed")),
            (.setZoom, WorkspaceIntentArgs.encode(id: extra.raw, flag: true)),
        ]
        for (op, args) in script {
            let status = await rig.document.apply(intent: op.rawValue, args: args)
            XCTAssertEqual(status, .applied, "\(op)")
            await settle(rig)
        }

        let hostState = await rig.document.snapshot
        let hostBytes = WorkspaceStateCodec.encodeSnapshot(hostState)
        for (index, client) in rig.clients.enumerated() {
            XCTAssertEqual(
                WorkspaceStateCodec.encodeSnapshot(client.mirror.entries), hostBytes,
                "client \(index) diverged from the host",
            )
        }
        // …and the projection agrees, which is the part a user would actually notice.
        let first = try XCTUnwrap(rig.clients[0].mirror.entries.topology)
        let second = try XCTUnwrap(rig.clients[1].mirror.entries.topology)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.tree.sessions[0].tabs[0].title, "build")
        XCTAssertEqual(first.tree.sessions[0].name, "renamed")
        XCTAssertTrue(first.syncInputTabs.contains(tabID))
        XCTAssertEqual(first.tree.sessions[0].tabs[0].zoomedPane, extra)
    }

    /// A client that joins LATE converges in one frame — a snapshot, self-contained, whatever it
    /// missed. Cost is bounded by the SIZE of the workspace, never by the duration of the absence.
    func testALateJoinerConvergesOnTheSameBytes() async {
        let (topology, _, tabID, _) = fixture()
        let rig = await makeRig(topology)
        defer { for session in rig.sessions { session.close() } }
        await settle(rig)

        for name in ["one", "two", "three", "four"] {
            _ = await rig.document.apply(
                intent: WorkspaceIntentOp.renameTab.rawValue,
                args: WorkspaceIntentArgs.encode(id: tabID.raw, name: name),
            )
            await settle(rig)
        }

        let latecomer = MirroringChannel()
        let session = WorkspaceChannelSession(
            channel: latecomer,
            subscribe: WorkspaceSubscribe(clientInstanceID: UUID(), clientKind: 0, label: "late"),
        )
        defer { session.close() }
        await rig.document.addSubscriber(session)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, latecomer.mirror.stateNum == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }

        let hostBytes = await WorkspaceStateCodec.encodeSnapshot(rig.document.snapshot)
        XCTAssertEqual(WorkspaceStateCodec.encodeSnapshot(latecomer.mirror.entries), hostBytes)
        XCTAssertEqual(latecomer.mirror.entries.topology?.tree.sessions[0].tabs[0].title, "four")
    }

    /// A REFUSED intent must move nothing anywhere. A rejection that half-applied would be the worst
    /// possible outcome: the asker rolls its patch back while everyone else keeps the change.
    func testARefusedIntentLeavesEveryClientWhereItWas() async {
        let (topology, _, _, _) = fixture()
        let rig = await makeRig(topology)
        defer { for session in rig.sessions { session.close() } }
        await settle(rig)
        let before = rig.clients.map { WorkspaceStateCodec.encodeSnapshot($0.mirror.entries) }
        let stateNumBefore = await rig.document.stateNum

        let status = await rig.document.apply(
            intent: WorkspaceIntentOp.renameTab.rawValue,
            args: WorkspaceIntentArgs.encode(id: UUID(), name: "ghost"),
        )
        XCTAssertEqual(status, .rejectedNotFound)
        await settle(rig)

        let stateNumAfter = await rig.document.stateNum
        XCTAssertEqual(stateNumAfter, stateNumBefore, "a refusal must not cost a version")
        XCTAssertEqual(rig.clients.map { WorkspaceStateCodec.encodeSnapshot($0.mirror.entries) }, before)
    }

    /// The idle host is SILENT. Every version bump costs every subscriber a frame, so an intent that
    /// asks for what is already true must not move `stateNum` — otherwise a client re-asserting its
    /// focus on a timer would keep every other device's link busy forever.
    func testAnIntentThatChangesNothingCostsNoVersion() async {
        let (topology, _, tabID, _) = fixture()
        let rig = await makeRig(topology)
        defer { for session in rig.sessions { session.close() } }
        await settle(rig)

        let args = WorkspaceIntentArgs.encode(id: tabID.raw, name: "one")
        let first = await rig.document.apply(intent: WorkspaceIntentOp.renameTab.rawValue, args: args)
        XCTAssertEqual(first, .applied)
        let after = await rig.document.stateNum
        await settle(rig)
        let second = await rig.document.apply(intent: WorkspaceIntentOp.renameTab.rawValue, args: args)
        XCTAssertEqual(second, .applied)

        let finally = await rig.document.stateNum
        XCTAssertEqual(finally, after, "renaming a tab to its own name is free")
    }
}
