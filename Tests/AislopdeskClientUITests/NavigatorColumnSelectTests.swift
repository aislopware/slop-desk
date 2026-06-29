// NavigatorColumnSelectTests — pins the FLOAT-AWARE pane→tab resolution the sidebar rail uses when a row is
// clicked (`NavigatorColumn.owningTabIndex(of:in:)`, the seam `NavigatorColumn.select` calls).
//
// The audited regression (E21 F1 class): `select` reimplemented the lookup as a hand-rolled
// `tab.root.allPaneIDs().contains(paneID)` scan, which sees the SPLIT TREE only — so a FLOATED pane living in
// a BACKGROUND tab (which DOES get a rail row, because `RailRowsBuilder` enumerates the float-aware
// `tab.allPaneIDs()`) never matched, the `selectTab(index)` call was skipped, and the E6 WI-3 tab-recency
// stamp (the only thing that floats the tab to the top of the `.updated` sidebar sort) was silently dropped.
// Clicking a tiled-pane row floated its background tab; clicking a floated-pane row in the same tab did not.
//
// Headless: a tree-model `WorkspaceStore` over the `MountTestPaneSession` fake (no socket / video / Metal —
// hang-safety). Each assertion FAILS on the pre-fix `tab.root.allPaneIDs()` resolution (it returns nil for a
// float), so neither is tautological.

import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class NavigatorColumnSelectTests: XCTestCase {
    /// A headless tree-model store over the fake session (mirrors `RailRowBuilderTests`).
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// Builds a two-tab session where TAB B (index 1) holds a FLOATED pane, then activates TAB A so tab B is a
    /// BACKGROUND tab. Returns the store, the floated pane's id, and tab B's id. The split before the float
    /// keeps a tiled sibling so floating does not empty tab B's tree (the op guards that).
    private func makeBackgroundFloatScenario() throws -> (store: WorkspaceStore, floatPane: PaneID, tabB: TabID) {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // tab B (index 1), now active
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let floatPane = try XCTUnwrap(
            store.tree.activeSession?.activeTab?.activePane,
            "split yields an active pane to float",
        )
        let tabB = try XCTUnwrap(store.tree.activeSession?.tabs[1].id, "tab B exists at index 1")
        store.toggleFloatActivePane()

        // Precondition: the pane really left the tiled tree for tab B's floating layer.
        let floatLayer = try XCTUnwrap(store.tree.activeSession?.activeTab?.floatingPanes)
        XCTAssertTrue(floatLayer.contains(floatPane), "precondition: the pane is in tab B's floating layer")

        store.selectTab(0) // activate tab A → tab B (holding the float) becomes a BACKGROUND tab
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 0, "precondition: tab A is active")
        return (store, floatPane, tabB)
    }

    /// THE core fix: the float-aware resolution finds the OWNING tab of a floated pane in a BACKGROUND tab.
    /// REVERT-TO-CONFIRM-FAIL: the pre-fix body `session.tabs.firstIndex { $0.root.allPaneIDs().contains(paneID) }`
    /// sees the split tree only, so it returns `nil` for a float — failing this `== 1` assertion.
    func testFloatedPaneInBackgroundTabResolvesItsOwningTab() throws {
        let (store, floatPane, _) = try makeBackgroundFloatScenario()
        let session = try XCTUnwrap(store.tree.activeSession)

        XCTAssertEqual(
            NavigatorColumn.owningTabIndex(of: floatPane, in: session), 1,
            "a floated pane in a background tab must resolve to its owning tab (index 1), not nil",
        )
    }

    /// The user-visible consequence: driving exactly what `NavigatorColumn.select` does on a row click —
    /// resolve the owning tab (float-aware) then `selectTab` it — stamps TAB B's recency (E6 WI-3), the stamp
    /// the pre-fix code skipped for floats. REVERT-TO-CONFIRM-FAIL: with the pre-fix resolution the unwrap of
    /// `owningTabIndex` is `nil`, so `selectTab` is never called and tab B's recency is never stamped past its
    /// stale value — the divergence ("clicking a floated row does not float its tab in the `.updated` sort").
    func testSelectingFloatedBackgroundRowStampsOwningTabRecency() throws {
        let (store, floatPane, tabB) = try makeBackgroundFloatScenario()
        let session = try XCTUnwrap(store.tree.activeSession)
        let before = store.tabLastActiveAt[tabB]

        // The select(_:) sequence (the row-click path) against the float-aware seam.
        let resolved = try XCTUnwrap(
            NavigatorColumn.owningTabIndex(of: floatPane, in: session),
            "the floated background pane must resolve an owning tab (a nil here is the dropped-stamp regression)",
        )
        store.selectTab(resolved)

        let after = try XCTUnwrap(
            store.tabLastActiveAt[tabB],
            "selecting the floated row stamps tab B recency (E6 WI-3)",
        )
        if let before { XCTAssertGreaterThanOrEqual(after, before, "the stamp advances, never rewinds") }
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 1, "tab B is now the active tab")
    }
}
