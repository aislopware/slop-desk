import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// A store with no document does not write one.
///
/// `tree` is a projection: with `topology == nil` it is a workspace of zero sessions — the absence of
/// a layout, not an empty one. Both writers read it (`persistableSnapshot()` saves the tree,
/// `documentFactsSnapshot()` derives its pane ids from `tree.allPaneIDs()`), and the channel drops
/// the document on the way to EVERY re-subscribe (`stop()` → `box.reset()`), so an app quit or a
/// background at that moment would replace the layout and the cached folder names with nothing.
@MainActor
final class WorkspaceSaveWithoutDocumentTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-save-no-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // The @objc XCTestCase override must keep the throwing signature (a non-throwing
    // override of a throwing @objc method does not compile).
    // swiftlint:disable:next unneeded_throws_rethrows
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func seed() -> TreeWorkspace {
        let pane = PaneID()
        let session = Session(
            id: SessionID(),
            name: "slop-desk",
            tabs: [Tab(id: TabID(), title: "one", root: .leaf(pane), activePane: pane)],
            specs: [pane: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    /// RED before the writers checked for a document: quitting between `stop()` and the next
    /// subscription wrote an EMPTY `workspace.json`, so the layout was gone permanently — even for a
    /// later launch against a working host.
    func testTheLayoutSurvivesAQuitWhileTheDocumentIsGone() {
        let persistence = WorkspacePersistence(
            fileURL: directory.appendingPathComponent("workspace.json"),
        )
        let restored = seed()
        let store = WorkspaceStore(
            restoringTree: restored,
            makeSession: { FakePaneSession($0.spec) },
            persistence: persistence,
        )
        store.saveImmediately()
        XCTAssertEqual(persistence.loadTree().allPaneIDs(), restored.allPaneIDs(), "the seed reached disk")

        // What `WorkspaceChannelClient.stop()` does on the way to re-subscribing.
        store.workspaceMirror.reset()
        XCTAssertTrue(store.tree.sessions.isEmpty, "no document ⇒ no layout to render")

        store.saveImmediately()

        XCTAssertEqual(
            persistence.loadTree().allPaneIDs(), restored.allPaneIDs(),
            "the file still holds the layout the next launch restores from",
        )
    }

    /// The same rule for the per-pane facts: an empty cache cold-paints nothing, so a launch would
    /// show a rail of unnamed panes and respawn every shell in `$HOME`.
    func testTheCachedFactsSurviveAQuitWhileTheDocumentIsGone() throws {
        let cache = WorkspaceCacheStore(fileURL: directory.appendingPathComponent("workspace-cache.json"))
        let restored = seed()
        let pane = try XCTUnwrap(restored.allPaneIDs().first)
        let store = WorkspaceStore(
            restoringTree: restored,
            makeSession: { FakePaneSession($0.spec) },
            documentCache: cache,
            cacheHostKey: "mac-studio:7420",
        )
        store.setLastKnownCwd("/Volumes/Lacie/Workspace/oss/slop-desk", for: pane)
        store.saveDocumentCacheNow()
        XCTAssertFalse(cache.load(hostKey: "mac-studio:7420").isEmpty, "the cwd reached disk")

        store.workspaceMirror.reset()
        store.saveDocumentCacheNow()

        XCTAssertFalse(
            cache.load(hostKey: "mac-studio:7420").isEmpty,
            "the cached folder names outlive a dropped subscription",
        )
    }
}
