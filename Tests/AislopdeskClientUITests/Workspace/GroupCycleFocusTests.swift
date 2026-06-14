import XCTest
@testable import AislopdeskClientUI

/// Pins in-group focus cycling (⌃⌘] / ⌃⌘[): cycle focus through ONLY the focused pane's group, never
/// stepping onto unrelated panes on the canvas. An ungrouped pane cycles the ungrouped bucket.
@MainActor
final class GroupCycleFocusTests: XCTestCase {
    private func item(_ z: Int, group: PaneGroupID? = nil) -> CanvasItem {
        CanvasItem(
            id: PaneID(),
            spec: PaneSpec(kind: .terminal, title: "p\(z)"),
            frame: CGRect(x: CGFloat(z) * 400, y: 0, width: 360, height: 240),
            z: z,
            groupID: group,
        )
    }

    func testCyclesOnlyWithinTheFocusedPanesGroup() {
        let gid = PaneGroupID()
        let a = item(0, group: gid), b = item(1, group: gid), c = item(2) // C is ungrouped
        let store = WorkspaceStore(
            restoring: Workspace(
                canvas: Canvas(items: [a, b, c]),
                focusedPane: a.id,
                groups: [PaneGroup(id: gid, name: "G")],
            ),
            makeSession: { FakePaneSession($0) },
        )

        store.cycleFocusInGroup(forward: true)
        XCTAssertEqual(store.focusedPane, b.id, "forward within G: A → B")
        store.cycleFocusInGroup(forward: true)
        XCTAssertEqual(store.focusedPane, a.id, "wraps within G: B → A, never onto the ungrouped C")
        store.cycleFocusInGroup(forward: false)
        XCTAssertEqual(store.focusedPane, b.id, "back within G: A → B")
        // Throughout, focus never landed on C.
        XCTAssertNotEqual(store.focusedPane, c.id)
    }

    func testSingletonBucketHasNoCycleTarget() {
        // A lone ungrouped pane: the ungrouped bucket has one member, so the `count > 1` guard fires. Assert
        // the PURE target helper returns nil — FocusResolver.cycle would return the SAME pane for a
        // singleton, so only this guard distinguishes "no-op" from "re-focus self" (a behavioral
        // focusedPane==solo assertion would pass even with the guard removed).
        let solo = item(0)
        let store = WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: [solo]), focusedPane: solo.id),
            makeSession: { FakePaneSession($0) },
        )
        XCTAssertNil(store.inGroupCycleTarget(forward: true), "a singleton bucket has no cycle target (guard fired)")
        XCTAssertNil(store.inGroupCycleTarget(forward: false))
        store.cycleFocusInGroup(forward: true)
        XCTAssertEqual(store.focusedPane, solo.id, "and the public method leaves focus put")
    }

    func testUngroupedFocusedPaneCyclesTheUngroupedBucket() {
        // Two ungrouped panes + a separate group: cycling from an ungrouped pane stays among the ungrouped.
        let gid = PaneGroupID()
        let grouped = item(0, group: gid)
        let u1 = item(1), u2 = item(2)
        let store = WorkspaceStore(
            restoring: Workspace(
                canvas: Canvas(items: [grouped, u1, u2]),
                focusedPane: u1.id,
                groups: [PaneGroup(id: gid, name: "G")],
            ),
            makeSession: { FakePaneSession($0) },
        )
        store.cycleFocusInGroup(forward: true)
        XCTAssertEqual(store.focusedPane, u2.id, "cycles within the ungrouped bucket")
        store.cycleFocusInGroup(forward: true)
        XCTAssertEqual(store.focusedPane, u1.id, "wraps within the ungrouped bucket, never onto the grouped pane")
        XCTAssertNotEqual(store.focusedPane, grouped.id)
    }
}
