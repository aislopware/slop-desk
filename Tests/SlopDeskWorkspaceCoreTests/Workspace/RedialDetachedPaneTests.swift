import Foundation
import SlopDeskClient
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskWorkspaceCore

/// Regression: ``WorkspaceStore/redialDisconnectedPanes()`` used to walk only `tree.allPaneIDs()`,
/// so a pane detached into its own satellite window (docs/DECISIONS.md — detach ↔ reattach) never got
/// its channel redialed when the app-global connection (re)established, leaving it a dead, blank
/// terminal (the ``WorkspaceStore/reconcileTree()`` desired set is the union with
/// `tree.detachedPaneIDs()`; this helper must match).
@MainActor
final class RedialDetachedPaneTests: XCTestCase {
    /// An in-memory transport that resolves `connect()` without any real networking (same shape as
    /// `ConnectionViewModelConnectIfNeededTests.ImmediateTransport`).
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

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock()
            defer { lock.unlock() }
            return _count
        }

        func makeTransport() -> ImmediateTransport {
            lock.lock()
            _count += 1
            lock.unlock()
            return ImmediateTransport()
        }
    }

    /// A two-terminal-pane (`left` || `right`) tree store whose `makeSession` mints REAL
    /// `LivePaneSession`s backed by `rec`'s in-memory transport — the seam
    /// ``WorkspaceStore/redialDisconnectedPanes()`` actually acts on (it casts to `LivePaneSession`; the
    /// `FakePaneSession` seam used elsewhere would no-op it). Two panes so detaching `right` leaves
    /// `left` as the tree's sole leaf WITHOUT tripping the sole-pane reseed (docs/DECISIONS.md).
    private func makeStore(_ rec: Recorder) -> (WorkspaceStore, left: PaneID, right: PaneID) {
        let base = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "left"))
        let left = base.allPaneIDs()[0]
        let (ws, right) = WorkspaceTreeOps.splitPane(
            left, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "right"), in: base,
        )
        let store = WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: []), focusedPane: nil),
            restoringTree: ws,
            liveModel: .tree,
            makeSession: { spec in
                LivePaneSession.make(
                    spec,
                    makeClient: { _ in SlopDeskClient(makeTransport: { rec.makeTransport() }) },
                    makeInspector: { _ in nil },
                    target: { .default },
                )
            },
        )
        return (store, left, right)
    }

    private func megaYield() async { for _ in 0..<50 { await Task.yield() } }

    func testRedialReachesDetachedPane() async throws {
        let rec = Recorder()
        let (store, left, right) = makeStore(rec)
        store.detachPaneToWindow(right)
        XCTAssertTrue(store.tree.isDetached(right), "precondition: the pane left the tree into a satellite")
        XCTAssertTrue(store.tree.contains(left), "precondition: the sibling stayed tiled, no sole-pane reseed")

        let liveLeft = try XCTUnwrap(store.handle(for: left) as? LivePaneSession)
        let liveRight = try XCTUnwrap(store.handle(for: right) as? LivePaneSession)
        XCTAssertEqual(liveRight.connection?.status, .disconnected, "lazy-connect: nothing has dialed yet")

        store.redialDisconnectedPanes()
        await megaYield()

        XCTAssertEqual(rec.count, 2, "both the tiled AND the detached pane's channels were dialed")
        XCTAssertEqual(liveLeft.connection?.status, .connected)
        XCTAssertEqual(liveRight.connection?.status, .connected, "the satellite's channel is no longer dead")
    }
}
