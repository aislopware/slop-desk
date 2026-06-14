import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Store-level tests for the non-overlap drag commit (``WorkspaceStore/movePaneNonOverlapping(_:snapped:config:)``):
/// the rest-flush slide, the insert-intent make-space that parts neighbours, and the ⌘/setting-off
/// bypass that degrades to a plain move. Pairs with the pure ``CanvasNonOverlapTests``.
@MainActor
final class CanvasNonOverlapStoreTests: XCTestCase {
    private func makeStore(_ items: [CanvasItem], focused: PaneID, groups: [PaneGroup] = []) -> WorkspaceStore {
        WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: items), focusedPane: focused, groups: groups),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    private func item(_ id: PaneID, _ frame: CGRect, group: PaneGroupID? = nil) -> CanvasItem {
        CanvasItem(id: id, spec: PaneSpec(kind: .terminal, title: "p"), frame: frame, z: 0, groupID: group)
    }

    func testSlidesFlushWhenNotInserting() throws {
        let a = PaneID(), b = PaneID()
        let store = makeStore([
            item(a, CGRect(x: 0, y: 0, width: 200, height: 200)),
            item(b, CGRect(x: 400, y: 0, width: 200, height: 200)),
        ], focused: a)
        // Shallow approach (low coverage) → no insert; A slides flush one gutter off B, B untouched.
        store.movePaneNonOverlapping(a, snapped: CGRect(x: 250, y: 0, width: 200, height: 200), config: .init())
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: a)?.maxX),
            384,
            accuracy: 0.3,
            "flush at B.minX − gutter",
        )
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: b)?.minX),
            400,
            accuracy: 1e-6,
            "neighbour unmoved",
        )
    }

    func testInsertPartsTwoNeighboursSymmetrically() throws {
        let a = PaneID(), b = PaneID(), d = PaneID()
        let store = makeStore([
            item(a, CGRect(x: 0, y: 0, width: 300, height: 300)),
            item(b, CGRect(x: 300, y: 0, width: 300, height: 300)),
            item(d, CGRect(x: 900, y: 600, width: 200, height: 300)),
        ], focused: d)
        // Drop D onto the seam between the two adjacent panes → they part to admit it.
        store.movePaneNonOverlapping(d, snapped: CGRect(x: 200, y: 0, width: 200, height: 300), config: .init())
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: d)?.origin),
            CGPoint(x: 200, y: 0),
            "dragged pinned at the drop",
        )
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: a)?.minX),
            -116,
            accuracy: 0.01,
            "left parted left",
        )
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: b)?.minX),
            416,
            accuracy: 0.01,
            "right parted right",
        )
    }

    func testDisabledBypassIsPlainMoveEvenIfOverlapping() throws {
        let a = PaneID(), b = PaneID()
        let store = makeStore([
            item(a, CGRect(x: 0, y: 0, width: 200, height: 200)),
            item(b, CGRect(x: 400, y: 0, width: 200, height: 200)),
        ], focused: a)
        // ⌘ bypass → A lands exactly on the snapped target, overlapping B (a deliberate free stack).
        store.movePaneNonOverlapping(a, snapped: CGRect(x: 350, y: 0, width: 200, height: 200), config: .disabled)
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: a)?.minX),
            350,
            accuracy: 1e-6,
            "no slide under ⌘ bypass",
        )
    }

    // MARK: - Groups

    func testMoveGroupPartsOverlappedNeighbour() throws {
        let m = PaneID(), p = PaneID(), gid = PaneGroupID()
        let store = makeStore([
            item(m, CGRect(x: 0, y: 0, width: 300, height: 300), group: gid),
            item(p, CGRect(x: 400, y: 0, width: 300, height: 300)),
        ], focused: p, groups: [PaneGroup(id: gid, name: "G")])
        // Move the group box so its centre lands on the neighbour → insert-intent parts P.
        store.moveGroupNonOverlapping(gid, snappedBox: CGRect(x: 250, y: 0, width: 300, height: 300), config: .init())
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: m)?.minX),
            250,
            accuracy: 0.01,
            "the group's member moved rigidly to the box target",
        )
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: p)?.minX),
            566,
            accuracy: 0.01,
            "the neighbour parted (overlap + gutter)",
        )
    }

    func testResizeGroupShovesNeighbour() throws {
        let m = PaneID(), p = PaneID(), gid = PaneGroupID()
        let store = makeStore([
            item(m, CGRect(x: 0, y: 0, width: 200, height: 200), group: gid),
            item(p, CGRect(x: 260, y: 0, width: 200, height: 200)),
        ], focused: p, groups: [PaneGroup(id: gid, name: "G")])
        // Grow the group box rightward to (0,0,400,200) → it now overlaps P, which must be shoved clear.
        store.resizeGroupNonOverlapping(gid, newBox: CGRect(x: 0, y: 0, width: 400, height: 200), config: .init())
        XCTAssertEqual(
            store.workspace.canvas.frame(of: m),
            CGRect(x: 0, y: 0, width: 400, height: 200),
            "member rescaled to fill the new box",
        )
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: p)?.minX),
            416,
            accuracy: 0.01,
            "neighbour shoved one gutter clear of the grown box",
        )
    }

    func testResizeGroupShrinkKeepsMembersNonOverlapping() throws {
        let m1 = PaneID(), m2 = PaneID(), gid = PaneGroupID()
        let store = makeStore([
            item(m1, CGRect(x: 0, y: 0, width: 160, height: 120), group: gid),
            item(m2, CGRect(x: 320, y: 0, width: 160, height: 120), group: gid),
        ], focused: m1, groups: [PaneGroup(id: gid, name: "G")])
        // Shrink the group box to the floor: the affine remap floors both members at minItemSize while
        // packing their origins close → they would overlap. The within-group reflow must separate them.
        store.resizeGroupNonOverlapping(gid, newBox: CGRect(x: 0, y: 0, width: 160, height: 120), config: .init())
        let f1 = try XCTUnwrap(store.workspace.canvas.frame(of: m1))
        let f2 = try XCTUnwrap(store.workspace.canvas.frame(of: m2))
        XCTAssertTrue(f1.intersection(f2).isNull, "members must not overlap after a heavy group shrink")
    }

    func testWithinGroupMembersReflowOnMemberMove() throws {
        let m1 = PaneID(), m2 = PaneID(), gid = PaneGroupID()
        let store = makeStore([
            item(m1, CGRect(x: 0, y: 0, width: 200, height: 200), group: gid),
            item(m2, CGRect(x: 210, y: 0, width: 200, height: 200), group: gid),
        ], focused: m1, groups: [PaneGroup(id: gid, name: "G")])
        // Drag M1 onto its sibling M2 (same group): the top-level solve sees no obstacle, but the
        // within-group reflow parts M2 so members don't overlap each other.
        store.movePaneNonOverlapping(m1, snapped: CGRect(x: 150, y: 0, width: 200, height: 200), config: .init())
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: m1)?.minX),
            150,
            accuracy: 0.01,
            "dragged member at its target",
        )
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: m2)?.minX),
            366,
            accuracy: 0.01,
            "sibling reflowed clear",
        )
    }

    func testCommitFocusesAndRaisesDragged() throws {
        let a = PaneID(), b = PaneID()
        let store = makeStore([
            item(a, CGRect(x: 0, y: 0, width: 200, height: 200)),
            item(b, CGRect(x: 400, y: 0, width: 200, height: 200)),
        ], focused: b)
        store.movePaneNonOverlapping(a, snapped: CGRect(x: 250, y: 0, width: 200, height: 200), config: .init())
        XCTAssertEqual(store.workspace.focusedPane, a, "the dragged pane is focused")
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.item(a)?.z),
            store.workspace.canvas.maxZ,
            "and raised to front",
        )
    }
}
