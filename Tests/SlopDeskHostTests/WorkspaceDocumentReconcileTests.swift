import Foundation
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskWorkspaceModel

/// The reconciler's THREE-WAY decision, and the eviction hook next to it.
///
/// Both shipped with no test of their own. `WorkspaceDocumentChannelTests` drives
/// ``HostWorkspaceDocument/merge(paneLiveness:)-(PaneLiveness)`` and
/// ``HostWorkspaceDocument/removePanes(keeping:)`` and stops there, so the only two entries that
/// decide whether a pane is KEPT — ``HostWorkspaceDocument/reconcile(captured:)``, on a 500 ms
/// backstop plus every session-lifecycle event, and ``HostWorkspaceDocument/markPaneDead(_:)``, the
/// detached store's TTL eviction — were covered by nothing.
///
/// The case worth a file is the one the obvious rule gets wrong. "Reap whatever was not captured" is
/// correct only while the document holds liveness alone. Once topology lives here, a host that has
/// just restarted captures NOTHING — every pane is a real pane in a real tab that has not been given
/// a process yet — and the obvious rule deletes the user's entire layout on every restart, silently,
/// with the document's own version bump as the only trace. So the tests below are written against
/// the three OUTCOMES (kept live, kept stale, reaped) rather than against the loop that produces
/// them: that is the part a port to Rust has to keep, and the loop is not.
final class WorkspaceDocumentReconcileTests: XCTestCase {
    // MARK: - Fixture

    /// One session, one tab, two leaves — the smallest layout in which "in the topology" and "not in
    /// the topology" are both reachable for a pane the document knows about.
    private struct Layout {
        let topology: WorkspaceTopology
        let left: UUID
        let right: UUID
    }

    private func layout() -> Layout {
        let left = PaneID(), right = PaneID()
        let tab = Tab(
            title: "work",
            root: .split(id: SplitNodeID(), axis: .horizontal, children: [
                WeightedChild(weight: .flex(1), node: .leaf(left)),
                WeightedChild(weight: .flex(1), node: .leaf(right)),
            ]),
            activePane: left,
        )
        let session = Session(
            name: "slop-desk",
            tabs: [tab],
            specs: [
                left: PaneSpec(kind: .terminal, title: "nvim", userRenamed: true),
                right: PaneSpec(kind: .terminal, title: "Terminal"),
            ],
        )
        return Layout(
            topology: WorkspaceTopology(tree: TreeWorkspace(sessions: [session], activeSessionID: session.id)),
            left: left.raw,
            right: right.raw,
        )
    }

    /// A document already carrying the layout, the way a restored host starts.
    ///
    /// Restored, never pristine: a document that carries somebody's layout is exactly the kind that
    /// must refuse an upload, and a fixture that said otherwise would be testing the wrong host.
    private func restored(_ layout: Layout) async -> HostWorkspaceDocument {
        var state = HostWorkspaceState()
        state.write(topology: layout.topology)
        let document = HostWorkspaceDocument()
        await document.install(state: state, pristine: false)
        return document
    }

    private func liveness(_ document: HostWorkspaceState, _ paneID: UUID) -> PaneLiveness? {
        PaneLiveness(paneID: paneID, entries: document)
    }

    // MARK: - The restart case

    /// The whole reason the reap rule is three-way and not two-way.
    ///
    /// A host that has just restarted has a full topology and not one running process, so the capture
    /// is EMPTY. Every pane must survive — this is the user's layout, and it is the one thing a
    /// restart is supposed to preserve.
    func testARestartThatCapturesNothingKeepsEveryPaneInTheLayout() async {
        let layout = layout()
        let document = await restored(layout)

        await document.reconcile(captured: [])

        let after = await document.snapshot
        XCTAssertEqual(liveness(after, layout.left)?.liveness, .dead, "present, and honestly stale")
        XCTAssertEqual(liveness(after, layout.right)?.liveness, .dead)
        XCTAssertEqual(
            after.string(WorkspaceKey(.pane, layout.left, WorkspacePaneField.title)), "nvim",
            "the persisted title is a topology fact and a reconcile must not touch it",
        )
        XCTAssertNotNil(after.topology, "the layout is still decodable, which is what the user sees")
    }

    // MARK: - The three outcomes

    /// Captured → the capture wins, and the pane is not a reap candidate at all.
    func testACapturedPaneKeepsWhatTheCaptureSaid() async {
        let layout = layout()
        let document = await restored(layout)

        await document.reconcile(captured: [
            PaneLiveness(paneID: layout.left, liveness: .attached, liveTitle: "main.swift", titleFresh: true),
        ])

        let after = await document.snapshot
        let left = liveness(after, layout.left)
        XCTAssertEqual(left?.liveness, .attached)
        XCTAssertEqual(left?.liveTitle, "main.swift")
        XCTAssertEqual(left?.titleFresh, true)
        // …and the pane that was NOT captured took the other branch in the same pass.
        XCTAssertEqual(liveness(after, layout.right)?.liveness, .dead)
    }

    /// In the topology but not captured → STALE, keeping the two fields that describe a place rather
    /// than a process. Rendering it live is the fake-live bug; deleting it is the restart bug.
    func testAPaneThatStoppedBeingCapturedKeepsThePlaceAndDropsTheProcess() async {
        let layout = layout()
        let document = await restored(layout)
        await document.merge(paneLiveness: PaneLiveness(
            paneID: layout.left,
            liveness: .attached,
            liveTitle: "main.swift",
            cwd: "/Volumes/work/slop-desk",
            projectKey: "slop-desk",
            foregroundProcess: "nvim",
            runningCommand: "cargo test",
            agentLabel: "claude",
            commandRunning: true,
            grid: PaneLiveness.Grid(cols: 120, rows: 40),
        ))

        await document.reconcile(captured: [])

        let after = await document.snapshot
        let left = liveness(after, layout.left)
        XCTAssertEqual(left?.liveness, .dead)
        XCTAssertEqual(left?.cwd, "/Volumes/work/slop-desk", "the directory it worked in has not moved")
        XCTAssertEqual(left?.projectKey, "slop-desk", "or By-Project re-buckets every restored row")
        XCTAssertNil(left?.runningCommand, "a command cannot still be running with no process")
        XCTAssertNil(left?.foregroundProcess)
        XCTAssertNil(left?.agentLabel)
        XCTAssertNil(left?.grid)
        XCTAssertEqual(left?.commandRunning, false)
        XCTAssertNil(left?.liveTitle, "a live title is a claim about a process")
    }

    /// In neither → reaped. This is the case the two-way rule was actually for: a pane whose channel
    /// closed and whose tab entry is already gone, owned by nothing.
    func testAPaneWithNoTopologyAndNoCaptureIsReaped() async {
        let layout = layout()
        let document = await restored(layout)
        let orphan = UUID()
        await document.merge(paneLiveness: PaneLiveness(paneID: orphan, liveness: .attached, liveTitle: "gone"))
        let before = await document.snapshot
        XCTAssertNotNil(liveness(before, orphan), "precondition: the document knows the orphan")

        await document.reconcile(captured: [])

        let after = await document.snapshot
        XCTAssertNil(liveness(after, orphan), "nothing owns it")
        XCTAssertTrue(
            after.keys(ofKind: WorkspaceObjectKind.pane.rawValue, objectID: orphan).isEmpty,
            "reaped whole, not left as a husk of one field",
        )
        XCTAssertNotNil(liveness(after, layout.left), "and the layout's own panes are untouched by it")
    }

    /// An orphan that IS captured is not reaped — capture alone is title enough. A pane spawned
    /// between the topology write and this tick would otherwise be deleted on the tick that first
    /// saw it.
    func testACapturedPaneOutsideTheTopologyIsNotReaped() async {
        let layout = layout()
        let document = await restored(layout)
        let fresh = UUID()

        await document.reconcile(captured: [PaneLiveness(paneID: fresh, liveness: .attached, liveTitle: "sh")])

        let after = await document.snapshot
        XCTAssertEqual(liveness(after, fresh)?.liveTitle, "sh")
    }

    // MARK: - Versioning

    /// Every bump costs every subscriber a frame, and this runs at least twice a second on an idle
    /// host. A settled reconcile has to be silent.
    func testASettledReconcileIsNotAVersion() async {
        let layout = layout()
        let document = await restored(layout)
        await document.reconcile(captured: [])
        let settled = await document.stateNum

        let changed = await document.reconcile(captured: [])

        XCTAssertFalse(changed)
        let after = await document.stateNum
        XCTAssertEqual(after, settled, "an idle host must not churn a version number")
    }

    /// One tick that observed several changed panes costs ONE version, not one per pane.
    func testOneTickIsOneVersionHoweverManyPanesMoved() async {
        let layout = layout()
        let document = await restored(layout)
        let before = await document.stateNum

        await document.reconcile(captured: [
            PaneLiveness(paneID: layout.left, liveness: .attached, liveTitle: "a"),
            PaneLiveness(paneID: layout.right, liveness: .attached, liveTitle: "b"),
        ])

        let after = await document.stateNum
        XCTAssertEqual(after, before + 1)
    }

    // MARK: - The eviction hook

    /// `DetachedSessionStore` kills a session on a TTL. Without this the document goes stale with no
    /// signal and every client keeps rendering a live row for a shell that was reaped.
    func testMarkPaneDeadKeepsThePlaceAndDropsTheProcess() async {
        let layout = layout()
        let document = await restored(layout)
        await document.merge(paneLiveness: PaneLiveness(
            paneID: layout.left,
            liveness: .attached,
            liveTitle: "htop",
            cwd: "/etc",
            projectKey: "etc",
            runningCommand: "htop",
            commandRunning: true,
        ))

        let changed = await document.markPaneDead(layout.left)

        XCTAssertTrue(changed)
        let after = await document.snapshot
        let left = liveness(after, layout.left)
        XCTAssertEqual(left?.liveness, .dead)
        XCTAssertEqual(left?.cwd, "/etc")
        XCTAssertEqual(left?.projectKey, "etc")
        XCTAssertNil(left?.runningCommand)
        XCTAssertEqual(left?.commandRunning, false)
        XCTAssertEqual(
            after.string(WorkspaceKey(.pane, layout.left, WorkspacePaneField.title)), "nvim",
            "the topology half is not this verb's business",
        )
    }

    /// The TTL can fire on a pane that already went stale — a second eviction must not cost a frame.
    func testMarkingADeadPaneDeadAgainIsNotAVersion() async {
        let layout = layout()
        let document = await restored(layout)
        await document.markPaneDead(layout.left)
        let settled = await document.stateNum

        let changed = await document.markPaneDead(layout.left)

        XCTAssertFalse(changed)
        let after = await document.stateNum
        XCTAssertEqual(after, settled)
    }

    /// A reconcile pass and the eviction hook must agree, or a pane's rendering would depend on which
    /// of the two happened to notice first.
    func testEvictionAndReconcileLeaveAPaneInTheSameState() async {
        let layout = layout()
        let evicted = await restored(layout)
        let reconciled = await restored(layout)
        for document in [evicted, reconciled] {
            await document.merge(paneLiveness: PaneLiveness(
                paneID: layout.left, liveness: .attached, liveTitle: "htop", cwd: "/etc", runningCommand: "htop",
            ))
        }

        await evicted.markPaneDead(layout.left)
        await reconciled.reconcile(captured: [
            PaneLiveness(paneID: layout.right, liveness: .attached),
        ])

        let a = await evicted.snapshot
        let b = await reconciled.snapshot
        XCTAssertEqual(liveness(a, layout.left), liveness(b, layout.left))
    }
}
