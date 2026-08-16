import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// What does it actually cost to move the WHOLE document across a boundary?
///
/// `CLAUDE.md` says a measured regression is the only veto on a port, and the ruling that keeps
/// `WorkspaceTreeOps` in Swift (docs/DECISIONS.md) was an ASSUMPTION until this ran: that marshalling
/// a `TreeWorkspace` per gesture would cost a frame. It measures the path that would actually be
/// used — the document's own entry encoding, which the host already publishes over the network on
/// every change, so the encoder and decoder are the shipped ones and not a fixture.
///
/// It came out on the assumption's side. On this Mac Studio a realistic workspace (3 sessions, 5
/// tabs each, 4 panes each — 244 entries) costs ~2.8 ms to project, encode, decode and ingest: a
/// third of a 120 Hz frame, per gesture, for a divider drag that is otherwise a few hundred
/// microseconds. A hoarder's workspace (1,042 entries) costs ~12.6 ms and misses the frame outright.
/// So the tree ops keep their document in Swift and cross the RULE instead — the per-tab pre-order
/// walk, which is bounded by one tab rather than by the whole document.
///
/// It prints a µs/op table and asserts only a loose ceiling; a hard number would flake under load.
/// Run on this Mac Studio: `swift test --filter WorkspaceMarshalBenchTests`.
final class WorkspaceMarshalBenchTests: XCTestCase {
    /// Sink to stop the optimizer eliding the work being measured.
    private var sink = 0

    private func usPerOp(_ iterations: Int, _ block: () -> Void) -> Double {
        // Warm up (codegen, allocator caches) so the timed loop is steady-state.
        for _ in 0..<min(iterations, 200) { block() }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { block() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(iterations) / 1000.0
    }

    /// A workspace of `sessions × tabs × panes`, each tab a real split tree rather than a leaf.
    private func workspace(sessions: Int, tabs: Int, panes: Int) -> WorkspaceTopology {
        var built: [Session] = []
        for s in 0..<sessions {
            var madeTabs: [Tab] = []
            var specs: [PaneID: PaneSpec] = [:]
            for t in 0..<tabs {
                let ids = (0..<panes).map { _ in PaneID() }
                var root = SplitNode.leaf(ids[0])
                for (i, id) in ids.dropFirst().enumerated() {
                    root = root.splitting(
                        ids[i],
                        axis: i.isMultiple(of: 2) ? .horizontal : .vertical,
                        inserting: id,
                    ) ?? root
                }
                for id in ids {
                    specs[id] = PaneSpec(kind: .terminal, title: "nvim ~/code/slop-desk")
                }
                madeTabs.append(Tab(id: TabID(), title: "tab-\(t)", root: root, activePane: ids[0]))
            }
            built.append(Session(name: "session-\(s)", tabs: madeTabs, activeTabIndex: 0, specs: specs))
        }
        return WorkspaceTopology(tree: TreeWorkspace(sessions: built, activeSessionID: built[0].id))
    }

    /// One row of the table: a workspace shape and how many times to time it.
    private struct Shape {
        let name: String
        let sessions: Int
        let tabs: Int
        let panes: Int
        let iterations: Int
    }

    func testWholeDocumentMarshalCostIsMeasuredNotAssumed() {
        // Small: what a person actually has open. Large: a hoarder's workspace, ten times over.
        let shapes = [
            Shape(name: "1 session, 3 tabs, 3 panes", sessions: 1, tabs: 3, panes: 3, iterations: 2000),
            Shape(name: "3 sessions, 5 tabs, 4 panes", sessions: 3, tabs: 5, panes: 4, iterations: 500),
            Shape(name: "6 sessions, 8 tabs, 6 panes", sessions: 6, tabs: 8, panes: 6, iterations: 100),
        ]
        print("\n=== Whole-document marshal (µs/op, lower is better) ===")
        print(String(format: "%-30@ %8@ %8@ %8@ %8@", "shape", "entries", "project", "codec", "ingest"))
        var worst = 0.0
        for shape in shapes {
            let topology = workspace(sessions: shape.sessions, tabs: shape.tabs, panes: shape.panes)
            let entries = topology.entries()
            let state = HostWorkspaceState(entries)
            let bytes = WorkspaceStateCodec.encodeSnapshot(state)

            let project = usPerOp(shape.iterations) { sink &+= topology.entries().count }
            let codec = usPerOp(shape.iterations) {
                let blob = WorkspaceStateCodec.encodeSnapshot(state)
                sink &+= ((try? WorkspaceStateCodec.decodeSnapshot(blob))?.entries.count ?? 0)
            }
            let ingest = usPerOp(shape.iterations) { sink &+= WorkspaceTopology(entries: state) == nil ? 0 : 1 }
            print(String(
                format: "%-30@ %8d %8.1f %8.1f %8.1f",
                shape.name,
                entries.count,
                project,
                codec,
                ingest,
            ))
            worst = Swift.max(worst, project + codec + ingest)
            XCTAssertFalse(bytes.isEmpty)
        }
        print("one 120 Hz frame is 8333 µs; one 60 Hz frame is 16666 µs (sink: \(sink))\n")
        // Deliberately loose — this exists to catch an order-of-magnitude change, not jitter. The
        // assertion is NOT that a document crossing is cheap: the table above says the largest shape
        // costs more than a 120 Hz frame, which is the finding. It is that the cost has not run away.
        XCTAssertLessThan(worst, 100_000.0, "the whole-document round trip has changed by an order of magnitude")
    }
}
