// PaneDropGeometry — the rect math a drop resolves through, and the four numbers that tune it.
//
// Two paths ask these questions and they must never answer differently: the canvas compositor's LIVE
// in-tab resolution (a swap, a re-split, a dock, with the dragged pane's own rect excluded) and
// ``PaneDragResolver``'s cross-window INSERT resolution (a satellite drag has no live view to resolve
// in, and no source pane in this tab to exclude). Both are rectangles and fractions, so both live
// here — the moment one of them was a `some View`'s private helper, "what is a gutter" would have had
// two answers, one per framework, on the day the canvas is rewritten in AppKit.
//
// The four statics went untested for as long as they were view-target internals reachable only
// through their two callers. `PaneDropGeometryTests` pins them directly now: the gutter's clamp, the
// deepest-wins rule and its vertical tiebreak, the no-op-dock predicate's epsilon, and the dominant
// edge's own tiebreak.

import CoreGraphics
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// Tunable drop-zone geometry (a UI affordance, deliberately NOT env flags). The hovered target pane
/// is divided into a central SWAP box and four edge bands; the whole container gets an outer DOCK
/// gutter.
package enum PaneDropMetrics {
    /// Each edge band is this fraction of the target's width/height (so the central swap box is the
    /// middle `1 - 2·edgeBandFraction` — 40% at 0.30). A generous centre keeps the common swap easy;
    /// 30% bands stay aimable on small panes.
    package static let edgeBandFraction: CGFloat = 0.30
    /// The container outer DOCK gutter is `min(containerGutterMax, minDimension · containerGutterFraction)`.
    package static let containerGutterFraction: CGFloat = 0.06
    package static let containerGutterMax: CGFloat = 28
}

/// The pure rect math behind drop-zone resolution — shared between the canvas's live in-canvas
/// resolution and ``PaneDragResolver``'s cross-window INSERT resolution, so the two paths can never
/// disagree on what a gutter or an edge band is.
package enum PaneDropGeometry {
    /// The first leaf (in the given order) whose rect contains `location`, excluding the dragged
    /// `source` (`nil` for an INSERT drag — a satellite drop has no source pane to exclude). Iterating
    /// the ORDERED leaves (not an unordered dict) keeps the resolved target deterministic if a
    /// min-clamped, over-subscribed layout ever overlaps two rects.
    package static func leaf(
        at location: CGPoint,
        in leaves: [SplitTreeRenderModel.PlacedLeaf],
        excluding source: PaneID?,
    ) -> (PaneID, CGRect)? {
        for placed in leaves where placed.id != source && placed.rect.contains(location) {
            return (placed.id, placed.rect)
        }
        return nil
    }

    /// The container outer edge whose gutter contains `location` (deepest wins; tie → a vertical
    /// left/right edge), or `nil` if the cursor is in no gutter. An edge the `sourceRect` already fully
    /// spans is skipped (docking there changes nothing); `nil` for an INSERT drag — every edge is
    /// meaningful then.
    package static func containerEdge(
        at location: CGPoint, container: CGRect, sourceRect: CGRect?,
    ) -> PaneDropEdge? {
        guard container.width > 0, container.height > 0 else { return nil }
        let gutter = Double.minimum(
            Double(PaneDropMetrics.containerGutterMax),
            Double.minimum(Double(container.width), Double(container.height))
                * Double(PaneDropMetrics.containerGutterFraction),
        )
        let distances: [(edge: PaneDropEdge, dist: CGFloat)] = [
            (.left, location.x - container.minX),
            (.right, container.maxX - location.x),
            (.top, location.y - container.minY),
            (.bottom, container.maxY - location.y),
        ]
        var best: (edge: PaneDropEdge, dist: CGFloat)?
        for entry in distances {
            if let sourceRect, sourceSpans(sourceRect, entry.edge, container) { continue }
            guard entry.dist >= 0, Double(entry.dist) <= gutter else { continue }
            // Deepest into the gutter (smallest distance) wins; iteration order left,right,top,bottom makes a
            // vertical edge win an exact tie (matches the default mental model).
            if let current = best {
                if entry.dist < current.dist { best = entry }
            } else {
                best = entry
            }
        }
        return best?.edge
    }

    /// Whether `rect` already fully spans the container `edge` (so docking the pane there would be a no-op).
    package static func sourceSpans(_ rect: CGRect, _ edge: PaneDropEdge, _ container: CGRect) -> Bool {
        let eps: CGFloat = 1
        switch edge {
        case .left:
            return rect.minX <= container.minX + eps && rect.height >= container.height - eps
        case .right:
            return rect.maxX >= container.maxX - eps && rect.height >= container.height - eps
        case .top:
            return rect.minY <= container.minY + eps && rect.width >= container.width - eps
        case .bottom:
            return rect.maxY >= container.maxY - eps && rect.width >= container.width - eps
        }
    }

    /// The edge band the cursor (normalized `u`,`v` in the target) has penetrated deepest. With the
    /// MOVE band (< 0.5) it is called only when the cursor is NOT in the centre box, so at least one
    /// penetration is positive; band 0.5 (the INSERT drag) maps every interior point to its nearest
    /// edge. Exact tie → a vertical (left/right) edge.
    package static func dominantEdge(u: CGFloat, v: CGFloat, band: CGFloat) -> PaneDropEdge {
        let penetrations: [(edge: PaneDropEdge, pen: CGFloat)] = [
            (.left, band - u),
            (.right, u - (1 - band)),
            (.top, band - v),
            (.bottom, v - (1 - band)),
        ]
        var best = penetrations[0]
        for entry in penetrations.dropFirst() where entry.pen > best.pen { best = entry }
        return best.edge
    }
}
