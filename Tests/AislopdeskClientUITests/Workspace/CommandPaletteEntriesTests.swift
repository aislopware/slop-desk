import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Pins the command-palette catalog + per-pane entry builder: the "Reconnect Pane" command surfaces
/// and ranks under "recon", and `buildPaneEntries` emits one jump-to-pane entry per canvas pane,
/// subtitled by its owning group (single-canvas model — there is no tab layer). Pure seams — the fuzzy
/// scorer and `buildPaneEntries` are tested directly, no SwiftUI render. `.reconnectPane` / `.renamePane`
/// command routing is asserted against the store via `apply(_:to:)` with the `FakePaneSession` seam.
@MainActor
final class CommandPaletteEntriesTests: XCTestCase {

    #if canImport(SwiftUI)

    // MARK: - Catalog contains Reconnect Pane + fuzzy ranks it

    func testCatalogContainsReconnectPane() {
        let hasReconnect = CommandPaletteView.commandCatalog.contains { $0.command == .reconnectPane }
        XCTAssertTrue(hasReconnect, "the palette catalog must offer Reconnect Pane")
    }

    func testFuzzyRanksReconnectForReconQuery() {
        // "recon" is a contiguous-prefix subsequence of "Reconnect Pane" ⇒ a positive (high) score.
        let score = CommandPaletteView.fuzzyScore(query: "recon", in: "Reconnect Pane")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
        // A non-subsequence query does not match.
        XCTAssertNil(CommandPaletteView.fuzzyScore(query: "xyz", in: "Reconnect Pane"))
    }

    // MARK: - buildPaneEntries

    /// Every pane on the canvas yields exactly one jump-to-pane entry carrying its `PaneID`, titled by
    /// the leaf spec; an ungrouped pane is subtitled "Pane" while a grouped pane is "Pane in <group>".
    func testBuildPaneEntriesOneEntryPerPaneWithGroupSubtitle() {
        let groupedID = PaneID(), ungroupedID = PaneID()
        let group = PaneGroup(name: "Work")
        let workspace = Workspace.make(
            panes: [
                (groupedID, PaneSpec(kind: .terminal, title: "Left")),
                (ungroupedID, PaneSpec(kind: .claudeCode, title: "Right")),
            ],
            focused: groupedID,
            groups: [group]
        ).assigning(pane: groupedID, toGroup: group.id)

        let entries = CommandPaletteView.buildPaneEntries(workspace: workspace)

        XCTAssertEqual(entries.count, 2, "one entry per pane on the canvas")
        // Each entry carries its PaneID.
        let paneIDs: [PaneID] = entries.compactMap { entry in
            if case let .pane(p) = entry.kind { return p }
            return nil
        }
        XCTAssertEqual(Set(paneIDs), [groupedID, ungroupedID])
        // Titles come from the leaf specs.
        XCTAssertEqual(Set(entries.map(\.title)), ["Left", "Right"])
        // Subtitle reflects group membership.
        let byID = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (PaneID, String?)? in
            if case let .pane(p) = entry.kind { return (p, entry.subtitle) }
            return nil
        })
        XCTAssertEqual(byID[groupedID], "Pane in Work", "a grouped pane names its group")
        XCTAssertEqual(byID[ungroupedID], "Pane", "an ungrouped pane is plain 'Pane'")
    }

    #endif

    // MARK: - apply(.reconnectPane) routing

    /// `apply(.reconnectPane)` is a graceful no-op against the `FakePaneSession` seam (no live
    /// connection) — it must not trap and must not mutate the canvas / registry.
    func testApplyReconnectPaneIsSafeWithFakeSession() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let before = store.workspace
        let sessions = store.allSessions.count

        apply(.reconnectPane, to: store)   // focused pane has a FakePaneSession (no connection) ⇒ no-op

        XCTAssertEqual(store.workspace, before, "reconnect must not mutate the canvas")
        XCTAssertEqual(store.allSessions.count, sessions, "reconnect must not touch the registry")
    }

    /// `apply(.reconnectPane)` with no focused pane is a graceful no-op (no target to reconnect).
    func testApplyReconnectPaneNoopWithNoFocusedPane() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        store.closePane(store.focusedPane!)   // close the only pane → empty canvas, no focus
        XCTAssertNil(store.focusedPane)
        apply(.reconnectPane, to: store)   // must not trap
        XCTAssertNil(store.focusedPane)
    }

    // MARK: - apply(.renamePane) wiring

    /// `apply(.renamePane)` bumps `renameRequest` so the sidebar opens its inline rename field on the
    /// focused pane — the ⌘R / menu / palette "Rename Pane" entry point.
    func testApplyRenamePaneBumpsRenameRequestWithFocusedPane() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        XCTAssertNotNil(store.focusedPane)
        let before = store.renameRequest
        apply(.renamePane, to: store)
        XCTAssertEqual(store.renameRequest, before + 1, "rename request bumps so the sidebar opens the field")
    }

    /// With no focused pane, `apply(.renamePane)` is a graceful no-op (nothing to rename).
    func testApplyRenamePaneNoopWithNoFocusedPane() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        store.closePane(store.focusedPane!)   // close the only pane → no focus
        XCTAssertNil(store.focusedPane)
        let before = store.renameRequest
        apply(.renamePane, to: store)   // must not trap
        XCTAssertEqual(store.renameRequest, before, "no focused pane → no rename request")
    }
}
