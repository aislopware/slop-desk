// PaneCanvasDrop — the IN-TAB half of a pane drop: which zone a cursor is over, and the one store op a
// release there commits.
//
// ``PaneDragCommit`` already owns the CROSS-container half — the four destinations a pane can land in
// when it leaves its own tab, in the op family its ``PaneDragOrigin`` names. What that decision
// deliberately leaves behind is the vocabulary only the canvas can commit: a SWAP with a sibling, a
// re-split BESIDE one, and a DOCK on the tab's own root edge. Those are three different store verbs
// picked by a four-case fork, which makes them a decision — and it was written inside the compositor's
// `some View`, one framework rewrite away from being written twice.
//
// The RESOLUTION is here for the same reason its geometry already is (``PaneDropGeometry``): the
// precedence — container gutter first, then a target leaf's centre box versus its edge bands — is the
// rule, and the rects it reads are values. What stays in the view is the gesture that supplies the
// cursor point and the `store.<op>()` that runs the answer.

import CoreGraphics
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The canvas's own drop vocabulary: resolve a point to a zone, then commit that zone.
@MainActor
package enum PaneCanvasDrop {
    /// Resolves the cursor `location` to the drop action a release would commit.
    ///
    /// PRECEDENCE, and it is the whole rule: the container's outer DOCK gutter first (a full-span
    /// dock), then — over a non-source target leaf — its CENTRE box (swap) versus an EDGE band
    /// (re-split). Empty space, or the source's own pane, resolves `.none`, which is a cancel: a
    /// release there commits nothing rather than guessing.
    ///
    /// The gutter check suppresses an edge the source ALREADY fully spans (docking there is a visual
    /// no-op — it also keeps grabbing the top/edge pane from instantly previewing a dock).
    package static func zone(
        at location: CGPoint,
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
        source: PaneID,
        sourceRect: CGRect,
    ) -> PaneDropZone {
        // 1) Container outer gutter → dock.
        if let edge = PaneDropGeometry.containerEdge(
            at: location, container: container, sourceRect: sourceRect,
        ) {
            return .dock(edge: edge)
        }
        // 2) Over a target leaf (not the source): centre → swap, edge band → re-split.
        guard let (target, rect) = PaneDropGeometry.leaf(at: location, in: leaves, excluding: source),
              rect.width > 0, rect.height > 0
        else {
            return .none
        }
        let u = (location.x - rect.minX) / rect.width
        let v = (location.y - rect.minY) / rect.height
        let band = PaneDropMetrics.edgeBandFraction
        let inCentreX = u >= band && u <= 1 - band
        let inCentreY = v >= band && v <= 1 - band
        if inCentreX, inCentreY {
            return .swap(target: target)
        }
        return .resplit(target: target, edge: PaneDropGeometry.dominantEdge(u: u, v: v, band: band))
    }

    /// Commits an in-tab `zone` for `pane` with exactly ONE store op.
    ///
    /// One op, on release, and never per drag frame: the drag itself is view-local, so the terminal
    /// grid resize / remote-window re-capture fires once here rather than on every cursor sample.
    /// `.none` is a cancel and commits nothing.
    ///
    /// The cross-tab twins of the last two cases are ``PaneDragCommit``'s — a pane whose tab was
    /// spring-loaded away mid-drag lands there, not here, because it is no longer moving inside the
    /// tab it started in.
    package static func commit(_ zone: PaneDropZone, pane: PaneID, in store: WorkspaceStore) {
        switch zone {
        case .none:
            break
        case let .swap(target):
            store.swapPanesTree(pane, target)
        case let .resplit(target, edge):
            store.moveLeafTree(pane, beside: target, axis: edge.axis, before: edge.insertsBefore)
        case let .dock(edge):
            store.moveLeafToRootEdgeTree(pane, edge: edge)
        }
    }
}
