import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Publishes an arbitrary tree straight into a store's in-process document.
///
/// The store's own mutators are intents, and an intent is validated — so a handful of states are
/// unreachable through them by design: a workspace with ZERO sessions, or a tab carrying a `.desktop`
/// leaf (video never enters the tree, docs/DECISIONS.md 2026-07-23). Those states still have
/// defensive contracts worth pinning, and this is how a test gets to one: it plays the HOST, which is
/// the only thing entitled to say what the layout is.
@MainActor
extension WorkspaceStore {
    /// - Throws: when the store holds no loopback document — the caller forgot
    ///   ``attachLoopbackWorkspaceDocument(label:)``, which would otherwise present as a silent no-op.
    func graftDocumentTree(
        _ tree: TreeWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        let document = try XCTUnwrap(
            workspaceChannel?.localDocumentForTesting,
            "graftDocumentTree needs a loopback document", file: file, line: line,
        )
        var next = document.snapshot
        var topology = next.topology ?? WorkspaceTopology(tree: tree)
        topology.tree = tree
        next.write(topology: topology)
        document.mutate { $0 = next }
    }
}
