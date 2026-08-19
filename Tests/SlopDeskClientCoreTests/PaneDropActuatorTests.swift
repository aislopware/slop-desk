// PaneDropActuatorTests — the drop ACTUATOR must act on the pane the cursor was dropped
// ONTO, not whichever pane happens to be focused. A drop delegate carries no focus signal of its own and a
// drop never moves focus (a pane is focused only on tap), so without care a Split-Left/Right or Open-In-Place
// drop onto a NON-focused sibling would split / replace the FOCUSED pane instead — a split-brained actuation
// (the verbatim-inject / host-open arms already target the dropped pane's own terminal model, while the
// `splitActivePane` arm reads the ACTIVE pane). The fix threads the dropped-on pane's `PaneID`
// into `actuate` and focuses it FIRST, so every active-pane-reading ingress resolves to the dropped-on pane.
//
// These drive the `@MainActor` ``PaneDropActuator/actuate(_:store:terminalModel:overlay:paneID:)`` directly
// (a real `DropInfo` can't be synthesized in a unit test) on a MULTI-pane tree whose focused pane (A) is NOT
// the drop target (B), and assert the new split is a direct sibling of B — NOT A. Revert-to-confirm-fail:
// drop the `store.focusPaneTree(paneID)` line from `actuate` and the split test fails (the new split lands
// beside the focused A instead of the dropped-on B). A store-level test that only ever exercises a
// single-pane store would miss this class of bug.
//
// The suite moved here with the code under test (docs/56): the actuator holds no SwiftUI type and never did,
// so neither does its test — which is the point, because the AppKit and UIKit delegates commit through this
// same function and a rule only a SwiftUI target could test is a rule the other halves will re-derive.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

@MainActor
final class PaneDropActuatorTests: XCTestCase {
    /// A live tree-model store whose sessions are headless doubles (no socket).
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
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

    // MARK: Read-only gate — a read-only terminal pane is INERT to drops (parity with the paste halt)

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

        PaneDropActuator.actuate(
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

        PaneDropActuator.actuate(
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
        PaneDropActuator.actuate(
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

    // MARK: The advisory toast — a folder → New-Tab `cd` is HOST-resolved, so it is advised, never blocked

    /// The advisory names the dropped path and carries the FIXED id that de-dupes repeated drops down to one
    /// card. Both halves push this same toast, so the wording is pinned here rather than in either renderer.
    func testCwdAdvisoryToastNamesThePathAndDeDupes() {
        let toast = PaneDropActuator.cwdAdvisoryToast(for: "/Users/me/project")
        XCTAssertEqual(toast.id, "drop-cwd", "a fixed id collapses repeated drops to ONE advisory")
        XCTAssertEqual(toast.flavor, .attention)
        XCTAssertEqual(toast.title, "cd'd on host")
        XCTAssertEqual(
            toast.body, "/Users/me/project is resolved on the host; it may not exist there.",
            "the advisory names the dropped path — the user cannot otherwise see which one was resolved",
        )
        XCTAssertNil(toast.paneKey, "the drop already focused the pane, so a jump door would land where we are")
    }
}
