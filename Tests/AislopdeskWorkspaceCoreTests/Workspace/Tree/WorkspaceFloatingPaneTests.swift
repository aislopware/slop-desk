import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pure floating-pane operations (P5a — zellij-style floating/scratch panes).
///
/// These pin the floating-overlay contract the store + view lean on: `toggleFloating` moves a pane
/// between the tiled tree and `tab.floatingPanes` (stamping / clearing `spec.floatingFrame`) while
/// preserving the **specs == leafIDs invariant** (`Tab.allPaneIDs()` counts the floating layer);
/// `spawnFloating` mints a brand-new floating pane; `moveFloating`/`resizeFloating` clamp the frame;
/// `closePane` of a float drops it from BOTH the floating layer and the spec table (no dangling ghost);
/// and `normalizingActive()` keeps a FLOATING active pane (does not reset it to a tiled leaf).
///
/// Each test asserts a value that cannot exist before the ops do (revert-to-confirm-fail = the op /
/// `PaneSpec.floatingFrame` / `Layout.floatingLeaves` is absent → compile failure). Headless: no
/// GhosttySurface / NSWindow / view — pure value transforms only.
final class WorkspaceFloatingPaneTests: XCTestCase {
    // MARK: Fixtures

    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func termSpec(_ title: String = "Terminal") -> PaneSpec {
        PaneSpec(kind: .terminal, title: title)
    }

    /// A workspace whose single tab has TWO tiled leaves (so one can float without emptying the tree).
    private func twoLeaves() -> (TreeWorkspace, PaneID, PaneID) {
        let ws = TreeWorkspace.singlePane(spec: termSpec("a"))
        let a = ws.allPaneIDs()[0]
        let (after, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        return (after, a, b)
    }

    /// The invariant, FLOATING-AWARE: each session's spec keys equal the FULL leaf set (tree + floating),
    /// and every leaf resolves a spec.
    private func assertInvariant(_ ws: TreeWorkspace, file: StaticString = #filePath, line: UInt = #line) {
        for session in ws.sessions {
            XCTAssertEqual(
                Set(session.specs.keys), session.leafIDSet(),
                "specs == leafIDs invariant (tree + floating) broken for session \(session.id)",
                file: file, line: line,
            )
        }
        for id in ws.allPaneIDs() {
            XCTAssertNotNil(ws.spec(for: id), "every leaf must have a spec", file: file, line: line)
        }
    }

    private func activeTab(_ ws: TreeWorkspace) throws -> Tab {
        try XCTUnwrap(ws.activeSession?.activeTab)
    }

    // MARK: toggleFloating — float

    func testToggleFloatingMovesTiledLeafIntoFloatingLayerAndStampsFrame() throws {
        let (ws, a, b) = twoLeaves()
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let after = WorkspaceTreeOps.toggleFloating(b, defaultFrame: frame, bounds: bounds, in: ws)
        let tab = try activeTab(after)
        XCTAssertTrue(tab.floatingPanes.contains(b), "floated pane joins the floating layer")
        XCTAssertFalse(tab.root.contains(b), "floated pane leaves the tiled tree")
        XCTAssertTrue(tab.root.contains(a), "the sibling stays tiled")
        XCTAssertEqual(after.spec(for: b)?.floatingFrame, frame, "the spec records the (clamped) frame")
        XCTAssertEqual(tab.activePane, b, "the floated pane takes focus")
        XCTAssertTrue(after.allPaneIDs().contains(b), "still a leaf of the workspace (floating layer counts)")
        assertInvariant(after)
    }

    func testToggleFloatingIsNoOpWhenPaneIsTheTabsOnlyTiledLeaf() {
        let ws = TreeWorkspace.singlePane(spec: termSpec("solo"))
        let solo = ws.allPaneIDs()[0]
        let after = WorkspaceTreeOps.toggleFloating(
            solo, defaultFrame: .init(x: 0, y: 0, width: 400, height: 300), bounds: bounds, in: ws,
        )
        XCTAssertEqual(after, ws, "floating the only tiled leaf would empty the tree → no-op")
    }

    func testToggleFloatingClearsZoomWhenFloatingTheZoomedPane() throws {
        let (ws0, _, b) = twoLeaves()
        let ws = WorkspaceTreeOps.toggleZoom(b, in: ws0)
        XCTAssertEqual(try activeTab(ws).zoomedPane, b)
        let after = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws,
        )
        XCTAssertNil(try activeTab(after).zoomedPane, "floating the zoomed pane clears the dangling zoom")
    }

    // MARK: kind-generic — a .remoteGUI pane floats / spawns like a terminal (E21 WI-6 / ES-E21-3)

    func testToggleFloatingFloatsARemoteGUIPaneWithoutAKindGuard() throws {
        // The float op must be KIND-GENERIC: a `.remoteGUI` (streamed host window) pane floats with NO kind
        // guard, preserving its kind + stamping its frame — so "a remote window can be floated as a card" is
        // satisfied for free. A kind guard excluding `.remoteGUI` would fail this.
        let ws0 = TreeWorkspace.singlePane(spec: termSpec("term"))
        let term = ws0.allPaneIDs()[0]
        let (ws1, gui) = WorkspaceTreeOps.splitPane(
            term, axis: .horizontal, newSpec: PaneSpec(kind: .remoteGUI, title: "win"), in: ws0,
        )
        let frame = CGRect(x: 80, y: 60, width: 600, height: 400)
        let after = WorkspaceTreeOps.toggleFloating(gui, defaultFrame: frame, bounds: bounds, in: ws1)
        let tab = try activeTab(after)
        XCTAssertTrue(tab.floatingPanes.contains(gui), "the remote-window pane floated")
        XCTAssertFalse(tab.root.contains(gui), "and left the tiled tree")
        XCTAssertEqual(after.spec(for: gui)?.kind, .remoteGUI, "its kind survives the float (not coerced)")
        XCTAssertEqual(after.spec(for: gui)?.floatingFrame, frame, "with the stamped frame")
        assertInvariant(after)
    }

    func testSpawnFloatingMintsARemoteGUIFloatingPane() throws {
        let (ws, _, _) = twoLeaves()
        let frame = CGRect(x: 100, y: 100, width: 500, height: 350)
        let (after, newID) = WorkspaceTreeOps.spawnFloating(
            PaneSpec(kind: .remoteGUI, title: "win"), defaultFrame: frame, bounds: bounds, in: ws,
        )
        let tab = try activeTab(after)
        XCTAssertTrue(tab.floatingPanes.contains(newID), "a brand-new floating remote-window pane")
        XCTAssertFalse(tab.root.contains(newID), "the new pane is NOT in the tiled tree")
        XCTAssertEqual(after.spec(for: newID)?.kind, .remoteGUI, "the spawned float keeps the requested kind")
        XCTAssertEqual(after.spec(for: newID)?.floatingFrame, frame)
        assertInvariant(after)
    }

    // MARK: toggleFloating — embed back

    func testToggleFloatingEmbedsFloatBackIntoTreeAndClearsFrame() throws {
        let (ws, _, b) = twoLeaves()
        let floated = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws,
        )
        let embedded = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .zero, bounds: bounds, in: floated,
        )
        let tab = try activeTab(embedded)
        XCTAssertFalse(tab.floatingPanes.contains(b), "embedded pane leaves the floating layer")
        XCTAssertTrue(tab.root.contains(b), "embedded pane rejoins the tiled tree")
        XCTAssertNil(embedded.spec(for: b)?.floatingFrame, "the spec frame is cleared on embed")
        XCTAssertEqual(tab.activePane, b, "the embedded pane takes focus")
        assertInvariant(embedded)
    }

    // MARK: spawnFloating

    func testSpawnFloatingMintsANewFloatingPaneWithFrameAndFocus() throws {
        let (ws, _, _) = twoLeaves()
        let before = Set(ws.allPaneIDs())
        let frame = CGRect(x: 50, y: 60, width: 500, height: 350)
        let (after, newID) = WorkspaceTreeOps.spawnFloating(
            termSpec("scratch"), defaultFrame: frame, bounds: bounds, in: ws,
        )
        XCTAssertFalse(before.contains(newID), "a brand-new id is minted")
        let tab = try activeTab(after)
        XCTAssertTrue(tab.floatingPanes.contains(newID))
        XCTAssertFalse(tab.root.contains(newID), "the new pane is NOT in the tiled tree")
        XCTAssertEqual(after.spec(for: newID)?.kind, .terminal)
        XCTAssertEqual(after.spec(for: newID)?.floatingFrame, frame)
        XCTAssertEqual(tab.activePane, newID, "the new floating pane takes focus")
        assertInvariant(after)
    }

    // MARK: move / resize

    func testMoveFloatingMovesOriginKeepingSizeAndClamps() throws {
        let (ws0, _, b) = twoLeaves()
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let ws = WorkspaceTreeOps.toggleFloating(b, defaultFrame: start, bounds: bounds, in: ws0)
        let moved = WorkspaceTreeOps.moveFloating(b, to: CGPoint(x: 250, y: 200), bounds: bounds, in: ws)
        let frame = try XCTUnwrap(moved.spec(for: b)?.floatingFrame)
        XCTAssertEqual(frame.origin, CGPoint(x: 250, y: 200))
        XCTAssertEqual(frame.size, start.size, "move keeps the size")
    }

    func testMoveFloatingClampsOriginIntoBounds() throws {
        let (ws0, _, b) = twoLeaves()
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let ws = WorkspaceTreeOps.toggleFloating(b, defaultFrame: start, bounds: bounds, in: ws0)
        // Drag far off the bottom-right; origin must clamp so the rect stays fully inside bounds.
        let moved = WorkspaceTreeOps.moveFloating(b, to: CGPoint(x: 5000, y: 5000), bounds: bounds, in: ws)
        let frame = try XCTUnwrap(moved.spec(for: b)?.floatingFrame)
        XCTAssertEqual(frame.maxX, bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, bounds.maxY, accuracy: 0.001)
    }

    func testResizeFloatingClampsToMinSize() throws {
        let (ws0, _, b) = twoLeaves()
        let ws = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 100, y: 100, width: 400, height: 300), bounds: bounds, in: ws0,
        )
        let tiny = CGRect(x: 100, y: 100, width: 5, height: 5)
        let resized = WorkspaceTreeOps.resizeFloating(b, to: tiny, bounds: bounds, in: ws)
        let frame = try XCTUnwrap(resized.spec(for: b)?.floatingFrame)
        XCTAssertGreaterThanOrEqual(frame.width, WorkspaceTreeOps.floatingMinSize.width)
        XCTAssertGreaterThanOrEqual(frame.height, WorkspaceTreeOps.floatingMinSize.height)
    }

    func testMoveFloatingIsNoOpForATiledPane() {
        let (ws, _, b) = twoLeaves()
        // b is tiled (no floatingFrame) → moveFloating must do nothing.
        let after = WorkspaceTreeOps.moveFloating(b, to: CGPoint(x: 10, y: 10), bounds: bounds, in: ws)
        XCTAssertEqual(after, ws)
        XCTAssertNil(after.spec(for: b)?.floatingFrame)
    }

    // MARK: raiseFloating (z-order)

    func testRaiseFloatingMovesPaneToTheEndOfTheFloatingArray() throws {
        let (ws0, _, b) = twoLeaves()
        // Float b, then spawn a second float c; floatingPanes = [b, c] (c topmost).
        let withB = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws0,
        )
        let (withC, c) = WorkspaceTreeOps.spawnFloating(
            termSpec("c"), defaultFrame: .init(x: 50, y: 50, width: 400, height: 300), bounds: bounds, in: withB,
        )
        XCTAssertEqual(try activeTab(withC).floatingPanes, [b, c], "spawn order: c last (topmost)")
        // Raise b → it must become last (topmost), c slides down.
        let raised = WorkspaceTreeOps.raiseFloating(b, in: withC)
        XCTAssertEqual(try activeTab(raised).floatingPanes, [c, b], "raised float goes to the END (topmost)")
        assertInvariant(raised)
    }

    func testRaiseFloatingIsNoOpWhenAlreadyTopmostOrTiled() {
        let (ws0, a, b) = twoLeaves()
        let withB = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws0,
        )
        // b is the only / topmost float → raising it changes nothing (no reconcile churn).
        XCTAssertEqual(WorkspaceTreeOps.raiseFloating(b, in: withB), withB, "already-topmost float: no-op")
        // a is tiled → raising it is a no-op (not floating).
        XCTAssertEqual(WorkspaceTreeOps.raiseFloating(a, in: withB), withB, "tiled pane: no-op")
    }

    // MARK: embed anchor placement

    func testEmbedSplitsOffTheProvidedAnchorNotTheFirstLeaf() throws {
        // Three tiled leaves a|b|c, then float c. Embedding c with anchor=b must put c adjacent to b.
        let (ws0, a, b) = twoLeaves()
        let (ws1, c) = WorkspaceTreeOps.splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: ws0)
        let floated = WorkspaceTreeOps.toggleFloating(
            c, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws1,
        )
        let embedded = WorkspaceTreeOps.toggleFloating(
            c, defaultFrame: .zero, bounds: bounds, embedAnchor: b, in: floated,
        )
        let tab = try activeTab(embedded)
        XCTAssertTrue(tab.root.contains(c), "c rejoins the tree")
        // c must be b's sibling in the nearest enclosing split (split off the anchor), not a's.
        let solved = SplitLayoutSolver.solve(tab.root, in: bounds)
        let cRect = try XCTUnwrap(solved[c]), bRect = try XCTUnwrap(solved[b]), aRect = try XCTUnwrap(solved[a])
        XCTAssertLessThan(
            abs(cRect.midX - bRect.midX) + abs(cRect.midY - bRect.midY),
            abs(cRect.midX - aRect.midX) + abs(cRect.midY - aRect.midY),
            "embedded float lands geometrically nearer the anchor (b) than the first leaf (a)",
        )
        assertInvariant(embedded)
    }

    func testEmbedFallsBackToActiveThenFirstLeafForAStaleAnchor() throws {
        let (ws0, _, b) = twoLeaves()
        let floated = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws0,
        )
        // A stale anchor (a fresh id not in the tree) must not break embed — it falls back and re-inserts.
        let embedded = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .zero, bounds: bounds, embedAnchor: PaneID(), in: floated,
        )
        XCTAssertTrue(try activeTab(embedded).root.contains(b), "stale anchor still embeds (fallback path)")
        assertInvariant(embedded)
    }

    // MARK: close

    func testClosePaneRemovesFloatingPaneFromLayerAndSpec() throws {
        let (ws0, a, b) = twoLeaves()
        let ws = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws0,
        )
        let after = WorkspaceTreeOps.closePane(b, in: ws)
        let tab = try activeTab(after)
        XCTAssertFalse(tab.floatingPanes.contains(b), "the float is dropped from the floating layer")
        XCTAssertFalse(after.allPaneIDs().contains(b), "no dangling floating id survives")
        XCTAssertNil(after.spec(for: b), "the float's spec is dropped (no ghost re-seed)")
        XCTAssertTrue(after.allPaneIDs().contains(a), "the tiled sibling survives")
        assertInvariant(after)
    }

    func testClosingAFloatDoesNotCollapseTheTiledTree() {
        let (ws0, a, b) = twoLeaves()
        let ws = WorkspaceTreeOps.toggleFloating(
            a, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws0,
        )
        // Now b is the lone tiled leaf, a is floating. Closing a must NOT touch b's tab structure.
        let after = WorkspaceTreeOps.closePane(a, in: ws)
        XCTAssertTrue(after.allPaneIDs().contains(b))
        XCTAssertEqual(after.sessions.count, 1, "closing a float never cascades to session removal")
        assertInvariant(after)
    }

    // MARK: normalize keeps a floating active pane

    func testNormalizingActiveKeepsAFloatingActivePane() throws {
        let (ws0, _, b) = twoLeaves()
        let ws = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws0,
        )
        XCTAssertEqual(try activeTab(ws).activePane, b)
        let normalized = ws.normalized()
        XCTAssertEqual(
            try activeTab(normalized).activePane, b,
            "a floating active pane must survive normalize (not reset to a tiled leaf)",
        )
        assertInvariant(normalized)
    }

    func testNormalizingSpecsKeepsAFloatingPanesSpec() {
        let (ws0, _, b) = twoLeaves()
        let ws = WorkspaceTreeOps.toggleFloating(
            b, defaultFrame: .init(x: 10, y: 10, width: 400, height: 300), bounds: bounds, in: ws0,
        )
        let normalized = ws.normalizingSpecs()
        XCTAssertNotNil(normalized.spec(for: b), "the floating pane's spec is not dropped as an orphan")
        XCTAssertEqual(normalized.spec(for: b)?.floatingFrame, ws.spec(for: b)?.floatingFrame)
    }

    // MARK: clamp helper

    func testClampFloatingFramePassesThroughForDegenerateBounds() {
        let frame = CGRect(x: 10, y: 20, width: 400, height: 300)
        let clamped = WorkspaceTreeOps.clampFloatingFrame(frame, in: .zero)
        XCTAssertEqual(clamped, frame, "degenerate bounds returns the frame unchanged (never a NaN write)")
    }

    func testDefaultFloatingFrameIsCenteredAndFitsBounds() {
        let frame = WorkspaceTreeOps.defaultFloatingFrame(in: bounds)
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.001)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.001)
        XCTAssertEqual(frame.midX, bounds.midX, accuracy: 0.001, "centered horizontally")
        XCTAssertEqual(frame.midY, bounds.midY, accuracy: 0.001, "centered vertically")
    }
}
