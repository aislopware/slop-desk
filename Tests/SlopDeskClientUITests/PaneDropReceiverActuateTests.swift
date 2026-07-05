// PaneDropReceiverActuateTests (E18 WI-6) — the drop ACTUATOR must act on the pane the cursor was dropped
// ONTO, not whichever pane happens to be focused. `PaneDropReceiver` carries no focus signal of its own and a
// drop never moves focus (a pane is focused only on tap), so a Split-Left/Right or Open-In-Place drop onto a
// NON-focused sibling used to split / replace the FOCUSED pane instead — a split-brained actuation (the
// verbatim-inject / host-open arms already targeted the dropped pane's own terminal model, while the
// `splitActivePane` arm read the ACTIVE pane). The fix threads the dropped-on pane's `PaneID`
// into `actuate` and focuses it FIRST, so every active-pane-reading ingress resolves to the dropped-on pane.
//
// These drive the `@MainActor` `PaneDropReceiver.actuate` directly (a real `DropInfo` can't be synthesized in
// a unit test) on a MULTI-pane tree whose focused pane (A) is NOT the drop target (B), and assert the new
// split is a direct sibling of B — NOT A. Revert-to-confirm-fail: drop the `store.focusPaneTree(paneID)` line
// from `actuate` and the split test fails (the new split lands beside the focused A instead of the dropped-on
// B). The earlier store-level tests only ever exercised a single-pane store, so the bug slipped through.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class PaneDropReceiverActuateTests: XCTestCase {
    /// A live tree-model store whose sessions are headless doubles (no socket).
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// The set of pane ids that are DIRECT `.leaf` children of the split node that directly contains `id` as a
    /// leaf — i.e. `id` and its immediate siblings. `nil` if `id` is the lone root leaf (no parent split). Lets
    /// the assertions check WHICH pane the new split actually nested beside.
    private func directLeafSiblings(of id: PaneID, in node: SplitNode) -> Set<PaneID>? {
        guard case let .split(_, _, children) = node else { return nil }
        var directLeaves: [PaneID] = []
        for child in children {
            if case let .leaf(leafID) = child.node { directLeaves.append(leafID) }
        }
        if directLeaves.contains(id) { return Set(directLeaves) }
        for child in children {
            if let found = directLeafSiblings(of: id, in: child.node) { return found }
        }
        return nil
    }

    /// Build a tab with TWO stacked terminal leaves `(focused A, non-focused sibling B)` so a horizontal
    /// drop-split of B nests cleanly under B (the parent is a VERTICAL split → a horizontal split of B becomes
    /// a fresh nested split holding only B + the new pane), making the "sibling of B, not A" check unambiguous.
    private func makeFocusedAandSiblingB(_ store: WorkspaceStore) throws -> (a: PaneID, b: PaneID) {
        let a = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane, "seeded active pane")
        let before = Set(store.tree.allPaneIDs())
        store.splitActivePane(axis: .vertical, kind: .terminal)
        let b = try XCTUnwrap(store.tree.allPaneIDs().first { !before.contains($0) }, "the split added pane B")
        store.focusPaneTree(a)
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, a,
            "precondition: A is the FOCUSED pane and B is the non-focused sibling",
        )
        return (a, b)
    }

    // MARK: Read-only gate — a read-only terminal pane is INERT to drops (E17 parity with the paste halt)

    /// An Open-In-Place (`hostOpen`) drop onto a READ-ONLY terminal pane must NOT fire the host-open verb —
    /// `hostOpen` (unlike `injectText` → `sendInput`) does not self-gate read-only, so without the actuator
    /// gate a drop would bypass the read-only halt. Revert-to-confirm-fail: drop the `guard
    /// terminalModel?.isReadOnly != true` line from `actuate` and `onRequestOpenHostPath` fires.
    func testReadOnlyPaneRejectsOpenInPlaceDrop() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane, "seeded active pane")
        let model = TerminalViewModel()
        model.isReadOnly = true
        var opened: [String] = []
        model.onRequestOpenHostPath = { opened.append($0) }

        PaneDropReceiver.actuate(
            .hostOpen("/Users/me/file.txt"),
            store: store, terminalModel: model, overlay: nil, paneID: paneID,
        )
        XCTAssertTrue(opened.isEmpty, "a read-only terminal pane must not open-in-place on a drop")
    }

    /// Control: the SAME drop onto a WRITABLE pane DOES open-in-place — proving the gate blocks only the
    /// read-only case (it must not over-block the normal path).
    func testWritablePaneAllowsOpenInPlaceDrop() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane, "seeded active pane")
        let model = TerminalViewModel()
        model.isReadOnly = false
        var opened: [String] = []
        model.onRequestOpenHostPath = { opened.append($0) }

        PaneDropReceiver.actuate(
            .hostOpen("/Users/me/file.txt"),
            store: store, terminalModel: model, overlay: nil, paneID: paneID,
        )
        XCTAssertEqual(opened, ["/Users/me/file.txt"], "a writable pane opens-in-place on the host (control)")
    }

    // MARK: Split-Right (a dropped folder) onto a NON-focused pane splits THAT pane

    func testSplitInjectPathTargetsDroppedPaneNotFocusedPane() throws {
        let store = makeStore()
        let (a, b) = try makeFocusedAandSiblingB(store)
        let before = Set(store.tree.allPaneIDs())

        // Split-Right with a folder dropped ONTO B (the non-focused pane). The deferred `cd` is irrelevant
        // here — the split itself is synchronous, so the tree shape is settled the moment `actuate` returns.
        PaneDropReceiver.actuate(
            .splitInjectPath("/Users/me/project", leading: false),
            store: store, terminalModel: nil, overlay: nil, paneID: b,
        )

        let new = try XCTUnwrap(store.tree.allPaneIDs().first { !before.contains($0) }, "the drop added a leaf")
        XCTAssertEqual(store.tree.spec(for: new)?.kind, .terminal, "the dropped folder opened a terminal")
        let root = try XCTUnwrap(store.tree.activeSession?.activeTab?.root)
        let siblings = try XCTUnwrap(directLeafSiblings(of: new, in: root), "the new pane has a parent split")
        XCTAssertTrue(siblings.contains(b), "the new split is a sibling of the DROPPED-ON pane B")
        XCTAssertFalse(siblings.contains(a), "NOT a sibling of the focused pane A (the split-brain bug)")
    }
}
#endif
