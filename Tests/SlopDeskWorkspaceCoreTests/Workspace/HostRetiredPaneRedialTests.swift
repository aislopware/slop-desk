import Foundation
import SlopDeskClient
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// A pane whose channel the HOST closed is not dialled again.
///
/// Two clients hold one pane. Closing its tab on client A is a HOST-side topology delete, and the
/// host answers it in a fixed order: `channelClose` to every
/// subscriber first (`HostServer.reapPanesRemovedFromTopology`), the document frame that removes the
/// pane second (`reconcileWorkspaceDocument`). Client B therefore learns that the channel died one
/// round trip BEFORE it learns the pane is gone — and in that window its reconnect campaign treated
/// the close as a transport drop and re-opened the channel. A pane channel naming a session the host
/// no longer has is a fresh SPAWN, so a whole login shell was forked for a pane the user had just
/// closed. Measured on hardware, `slopdesk-guigate multiclient`:
///
///     mux channel  7 (conn …ADCA27): joined live session 5AD35312… as subscriber 1
///     mux channel 11 (conn …ADCA27): shell /bin/sh (pid 75883) attached for pane 5AD35312…
///
/// …the second line being client B re-dialling the pane the first line had just watched die.
///
/// The property: from the host's `channelClose` onward, NOTHING dials that pane — not the campaign,
/// not the leaf's connect-on-remount, not the store's re-dial fan-out. Suppressing the spawn by
/// letting the host refuse would not do; the channel must never be opened.
@MainActor
final class HostRetiredPaneRedialTests: XCTestCase {
    // MARK: - Rig

    /// A two-pane store whose leaves mint REAL ``LivePaneSession``s over `dials`' drivers — the seam
    /// that actually opens a channel (a `FakePaneSession` store cannot see this property).
    /// Two panes so closing one leaves the tree intact instead of tripping the sole-pane reseed.
    private func makeStore(_ dials: PaneDialLedger) -> (store: WorkspaceStore, kept: PaneID, doomed: PaneID) {
        let base = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "kept"))
        let kept = base.allPaneIDs()[0]
        let (tree, doomed) = TreeIntent.splitPane(
            kept, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "doomed"), in: base,
        )
        let store = WorkspaceStore(
            restoringTree: tree,
            makeSession: { seed in
                LivePaneSession.make(
                    paneID: seed.id, spec: seed.spec, spawnCwd: seed.spawnCwd,
                    makeClient: { _ in SlopDeskClient(driver: dials.make(for: seed.id)) },
                    makeInspector: { _ in nil },
                    target: { .default },
                )
            },
        )
        store.attachLoopbackWorkspaceDocument()
        return (store, kept, doomed)
    }

    private func megaYield() async { for _ in 0..<80 { await Task.yield() } }

    /// Watches for `pane` opening a SECOND channel and fails the instant one appears. A bounded
    /// watch, not a sleep-and-peek: the reconnect campaign's first attempt fires immediately (no
    /// backoff), so a re-dial that is going to happen has happened long before the deadline, and
    /// waiting cannot turn a red run green.
    private func expectNoRedial(
        _ pane: PaneID,
        _ dials: PaneDialLedger,
        what: String,
        within: Duration = .milliseconds(750),
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if dials.count(pane) > 1 {
                XCTFail(
                    "\(what): the pane opened \(dials.count(pane)) channels — the host spawns a fresh "
                        + "shell for every one of them",
                    file: file, line: line,
                )
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
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

    // MARK: - The window between the close and the diff

    /// The hardware repro, headless. The pane is live on this client; the host retires its channel;
    /// the document has not yet said the pane is gone. RED before the gate: the reconnect campaign
    /// re-opened the channel inside that window and the host forked a shell for it.
    func testAHostRetiredPaneIsNotRedialledBeforeTheDocumentRemovesIt() async {
        let dials = PaneDialLedger()
        let (store, _, doomed) = makeStore(dials)
        store.redialDisconnectedPanes()
        await expect("the doomed pane to come up") {
            (store.handle(for: doomed) as? LivePaneSession)?.connection?.status == .connected
        }
        XCTAssertEqual(dials.count(doomed), 1, "precondition: exactly one channel is open for the pane")

        // The host reaps the pane: `channelClose` to this subscriber. The document frame that
        // removes it is still a round trip away — this is the whole window.
        dials.driver(for: doomed)?.hostClose(.retired)

        await expectNoRedial(doomed, dials, what: "after the host closed the pane's channel")
        XCTAssertEqual(
            dials.count(doomed), 1,
            "the host said this pane is done; re-opening its channel spawns a shell nothing will attach to",
        )
        XCTAssertTrue(store.tree.contains(doomed), "the document has not removed the pane yet — this IS the window")
    }

    /// The other two dial paths have to hold as well, because a gate on one of them only moves the
    /// spawn: the leaf re-runs its connect task on every remount (a tab switch), and the store fans
    /// a re-dial across every pane when the app connection re-establishes.
    func testNeitherTheLeafRemountNorTheStoreFanOutRedialsARetiredPane() async throws {
        let dials = PaneDialLedger()
        let (store, _, doomed) = makeStore(dials)
        store.redialDisconnectedPanes()
        await expect("the doomed pane to come up") {
            (store.handle(for: doomed) as? LivePaneSession)?.connection?.status == .connected
        }
        let live = try XCTUnwrap(store.handle(for: doomed) as? LivePaneSession)
        dials.driver(for: doomed)?.hostClose(.retired)
        await megaYield()

        // The leaf's `.task(id:)` re-firing on a remount, and the store's recovery fan-out.
        await live.connection?.connectIfNeeded()
        store.redialDisconnectedPanes()

        await expectNoRedial(doomed, dials, what: "after a remount + a store re-dial fan-out")
        XCTAssertEqual(dials.count(doomed), 1, "a retired pane stays retired on every dial path")
    }

    /// …and the pane count is still exact once the document catches up: one channel for its whole
    /// life, and the pane leaves the tree with nothing outstanding.
    func testTheRetiredPaneLeavesTheTreeHavingOpenedExactlyOneChannel() async {
        let dials = PaneDialLedger()
        let (store, kept, doomed) = makeStore(dials)
        store.redialDisconnectedPanes()
        await expect("both panes to come up") { dials.dialled.count == 2 }
        dials.driver(for: doomed)?.hostClose(.retired)
        await megaYield()

        // The document diff lands: the pane is gone from the layout.
        store.closePaneTree(doomed)
        await expect("the pane to leave the tree") { !store.tree.contains(doomed) }
        await expectNoRedial(doomed, dials, what: "after the document removed the pane")

        XCTAssertEqual(dials.count(doomed), 1, "one pane, one shell, for its whole life")
        XCTAssertEqual(dials.count(kept), 1, "its sibling is untouched")
    }

    /// A retired pane reads as DISCONNECTED, not as reconnecting. The campaign is gated off, so a
    /// "reconnecting" chrome would be a spinner for a retry nobody is making — the frozen dot this
    /// codebase keeps closing elsewhere. `.disconnected` is what a drop with no recovery behind it
    /// actually is, and it is the state an explicit Reconnect acts on.
    func testARetiredPaneReadsDisconnectedRatherThanReconnecting() async throws {
        let dials = PaneDialLedger()
        let (store, _, doomed) = makeStore(dials)
        store.redialDisconnectedPanes()
        await expect("the pane to come up") {
            (store.handle(for: doomed) as? LivePaneSession)?.connection?.status == .connected
        }
        let live = try XCTUnwrap(store.handle(for: doomed) as? LivePaneSession)

        dials.driver(for: doomed)?.hostClose(.retired)

        await expect("the pane to settle on a definite state") {
            live.connection?.status == .disconnected
        }
        XCTAssertEqual(live.connection?.status, .disconnected)
    }

    /// The control, and the reason this cannot be a blanket "never re-dial": a plain transport DROP
    /// says nothing about the pane, so it must NOT be answered the way a retirement is.
    ///
    /// What the two answers are has changed, and this is where that shows. The campaign is
    /// `slopdesk-clientdriver`'s now: a plain drop leaves it RUNNING, so the pane reads
    /// `.reconnecting` and the store's fan-out is right to leave it alone — the recovery is already
    /// in flight, inside the driver that still holds the session, and a fan-out dial would mint a
    /// second one racing it. A retirement gates the campaign, so the pane reads `.disconnected` and
    /// STAYS there. The distinction the suite is about survives whole; what moved is which side is
    /// doing the recovering.
    func testAPlainLinkDropLeavesTheCampaignRunningRatherThanRetiringThePane() async throws {
        let dials = PaneDialLedger()
        let (store, _, doomed) = makeStore(dials)
        store.redialDisconnectedPanes()
        await expect("the pane to come up") {
            (store.handle(for: doomed) as? LivePaneSession)?.connection?.status == .connected
        }
        let live = try XCTUnwrap(store.handle(for: doomed) as? LivePaneSession)

        // A drop names no reason: the pane is not implicated, only the link.
        dials.driver(for: doomed)?.deliver(.disconnected(reason: "the link died"))

        await expect("the drop to settle on reconnecting") {
            if case .reconnecting = live.connection?.status { return true }
            return false
        }
        guard case .reconnecting = live.connection?.status else {
            XCTFail("a plain drop must read as reconnecting — the driver's ladder is running")
            return
        }

        // And the fan-out leaves it to that ladder rather than opening a second channel beside it.
        store.redialDisconnectedPanes()
        await expectNoRedial(doomed, dials, what: "while the driver's own campaign is still running")
    }
}
