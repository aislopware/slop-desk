import Foundation
import SlopDeskClient
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// An evicted subscriber can come back; a reaped pane cannot.
///
/// Under `SLOPDESK_PANE_FANOUT` the host closes a pane channel for two opposite reasons. The
/// document's reap (`HostServer.reapPanesRemovedFromTopology`) means the PANE is gone, and the
/// document frame that removes it is one round trip behind — so nothing on this client may dial it
/// again. The laggard eviction (`wireSubscriberEviction`) means only THIS client's attachment is
/// gone: the pane, its shell and its other members are all still there, and nothing will ever remove
/// the pane from this client's topology. Treating the two alike leaves the evicted client rendering
/// a pane it can never reattach to for the rest of the process's life.
///
/// So the two are told apart on the wire (``MuxCloseReason``) and answered differently here:
///
/// - neither is answered by REFLEX — the reconnect campaign is gated for both, because an instant
///   re-dial after an eviction re-joins to be evicted again and costs the host a state transfer
///   every lap;
/// - but the app-connection fan-out (`WorkspaceStore.redialDisconnectedPanes()`) DOES recover an
///   evicted pane, and still does not touch a retired one.
@MainActor
final class EvictedSubscriberRedialTests: XCTestCase {
    // MARK: - Doubles

    /// An in-memory PTY transport whose end can be any of the three kinds the client has to tell
    /// apart: the host REAPING the pane, the host EVICTING this subscriber, or the link dying.
    private actor ClosableTransport: ClientTransporting {
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>
        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        private(set) var hostCloseReason: MuxCloseReason?

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

        /// The document reaped this pane: a `channelClose` naming a session the host is dropping.
        func retireFromHost() {
            hostCloseReason = .retired
            continuation.finish()
        }

        /// The host evicted THIS subscriber for lagging: a `channelClose` whose pane keeps running.
        func evictFromHost() {
            hostCloseReason = .subscriberEvicted
            continuation.finish()
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }

    /// Which pane ids opened a channel, in order, plus the newest transport per pane so the test can
    /// play the host against the live one. Each entry is one `channelOpen` the host would answer
    /// with a state transfer.
    private final class Dials: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [PaneID] = []
        private var live: [PaneID: ClosableTransport] = [:]

        var dialled: [PaneID] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }

        func count(_ pane: PaneID) -> Int { dialled.filter { $0 == pane }.count }

        func transport(for pane: PaneID) -> ClosableTransport? {
            lock.lock()
            defer { lock.unlock() }
            return live[pane]
        }

        func makeTransport(for pane: PaneID) -> ClosableTransport {
            let transport = ClosableTransport()
            lock.lock()
            ids.append(pane)
            live[pane] = transport
            lock.unlock()
            return transport
        }
    }

    // MARK: - Rig

    /// A two-pane store whose leaves mint REAL ``LivePaneSession``s over `dials`' transport — the
    /// seam that actually opens a channel. Two panes so the pane under test is never the sole one.
    private func makeStore(_ dials: Dials) -> (store: WorkspaceStore, other: PaneID, subject: PaneID) {
        let base = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "other"))
        let other = base.allPaneIDs()[0]
        let (tree, subject) = WorkspaceTreeOps.splitPane(
            other, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "subject"), in: base,
        )
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { seed in
                LivePaneSession.make(
                    paneID: seed.id, spec: seed.spec, spawnCwd: seed.spawnCwd,
                    makeClient: { _ in SlopDeskClient(makeTransport: { dials.makeTransport(for: seed.id) }) },
                    makeInspector: { _ in nil },
                    target: { .default },
                )
            },
        )
        store.attachLoopbackWorkspaceDocument()
        return (store, other, subject)
    }

    /// Brings a store up and returns the pane under test, live on its first channel.
    private func makeLivePane(_ dials: Dials) async -> (store: WorkspaceStore, subject: PaneID) {
        let (store, _, subject) = makeStore(dials)
        store.redialDisconnectedPanes()
        await expect("the pane under test to come up") {
            (store.handle(for: subject) as? LivePaneSession)?.connection?.status == .connected
        }
        XCTAssertEqual(dials.count(subject), 1, "precondition: exactly one channel is open for the pane")
        return (store, subject)
    }

    /// Polls until `condition` holds; fails on timeout rather than stranding the strand.
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

    /// Watches for `pane` opening a SECOND channel and fails the instant one appears. Bounded, not a
    /// sleep-and-peek: the campaign's first attempt fires with no backoff at all, so a reflex
    /// re-dial has happened long before the deadline and waiting cannot turn a red run green.
    private func expectNoRedial(
        _ pane: PaneID,
        _ dials: Dials,
        what: String,
        within: Duration = .milliseconds(750),
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if dials.count(pane) > 1 {
                XCTFail(
                    "\(what): the pane opened \(dials.count(pane)) channels",
                    file: file, line: line,
                )
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - The evicted subscriber

    /// The headline. The host evicted this client for lagging; the pane is untouched and stays in
    /// the topology forever, so the ONLY thing that can bring the client back is a dial it makes
    /// itself. The app-connection fan-out is that dial — and gating it on "the host closed the
    /// channel" left the pane dead for the process lifetime.
    func testTheAppConnectionFanOutRecoversAnEvictedSubscriber() async {
        let dials = Dials()
        let (store, subject) = await makeLivePane(dials)

        await dials.transport(for: subject)?.evictFromHost()
        await expect("the eviction to settle") {
            (store.handle(for: subject) as? LivePaneSession)?.connection?.status == .disconnected
        }
        XCTAssertTrue(store.tree.contains(subject), "an eviction never removes the pane — this is the whole problem")

        // The app-global connection (re)establishes: `handleConnectionEstablished()` fans a re-dial
        // across every pane left disconnected.
        store.redialDisconnectedPanes()

        await expect("the evicted pane to reattach") { dials.count(subject) == 2 }
        XCTAssertEqual(dials.count(subject), 2, "the pane the host still holds is reattachable")
    }

    /// …and it comes back CONNECTED, not merely re-dialled: the recovery is a working pane, not a
    /// second channel that immediately falls over on the client's own refusal to re-open.
    func testTheRecoveredPaneIsLiveAgain() async {
        let dials = Dials()
        let (store, subject) = await makeLivePane(dials)
        await dials.transport(for: subject)?.evictFromHost()
        await expect("the eviction to settle") {
            (store.handle(for: subject) as? LivePaneSession)?.connection?.status == .disconnected
        }

        store.redialDisconnectedPanes()

        await expect("the pane to be live again") {
            (store.handle(for: subject) as? LivePaneSession)?.connection?.status == .connected
        }
    }

    /// The control that keeps the recovery honest: an eviction is answered by an EVENT, never by a
    /// reflex. The reconnect campaign stays gated, so nothing dials between the eviction and the
    /// fan-out — otherwise the client re-joins at once, is evicted again, and the host pays for a
    /// state transfer every lap.
    func testAnEvictionIsNotAnsweredByTheReconnectCampaign() async {
        let dials = Dials()
        let (store, subject) = await makeLivePane(dials)

        await dials.transport(for: subject)?.evictFromHost()

        await expectNoRedial(subject, dials, what: "after the host evicted this subscriber")
        XCTAssertEqual(dials.count(subject), 1, "no campaign, no churn loop")
        _ = store
    }

    /// An evicted pane reads as DISCONNECTED, not as reconnecting: no campaign is running, so a
    /// "reconnecting" chrome would be a spinner for a retry nobody is making — and `.disconnected`
    /// is the state both the fan-out and an explicit Reconnect act on.
    func testAnEvictedPaneReadsDisconnectedRatherThanReconnecting() async throws {
        let dials = Dials()
        let (store, subject) = await makeLivePane(dials)
        let live = try XCTUnwrap(store.handle(for: subject) as? LivePaneSession)

        await dials.transport(for: subject)?.evictFromHost()

        await expect("the pane to settle on a definite state") { live.connection?.status == .disconnected }
        XCTAssertEqual(live.connection?.status, .disconnected)
    }

    // MARK: - The reaped pane, unchanged

    /// The contrast, in the same rig, because the recovery above is only correct if it does NOT
    /// leak to the other close. A reaped pane's session id is about to stop existing, so the
    /// fan-out must still leave it alone — re-opening it is a fresh login shell for a pane that is
    /// one round trip from leaving the layout.
    func testTheFanOutStillLeavesAReapedPaneAlone() async {
        let dials = Dials()
        let (store, subject) = await makeLivePane(dials)

        await dials.transport(for: subject)?.retireFromHost()
        await expect("the retirement to settle") {
            (store.handle(for: subject) as? LivePaneSession)?.connection?.status == .disconnected
        }

        store.redialDisconnectedPanes()

        await expectNoRedial(subject, dials, what: "after the document reaped the pane")
        XCTAssertEqual(dials.count(subject), 1, "one pane, one shell, for its whole life")
    }
}
