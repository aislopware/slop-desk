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
//
// THE PREVIEW'S RECTS ARE HERE TOO, and they arrived one increment later than the resolver's for a
// reason worth naming. `slabRect` / `seamSize` / `seamCenter` / `railRect` were `static func`s ON A
// `View` — `PaneMoveOverlay`'s, under a banner that already called them "pure rect math" — so the
// increment that swept this directory by IMPORT EDGE never saw them: a method on a view struct is
// not a view, but it is unreachable from anything that is not one. That is the same shape docs/56
// increment 54 found in `SlateEmptyState.Cause`, and §3's test is per-DECLARATION for exactly this.
// They resolve the drop's ANSWER into rectangles, where the four above resolve a point into the
// answer; both halves of that round trip have to agree, and an AppKit canvas that re-derived the
// second half by eye would draw a preview for a drop the shared resolver never commits.

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

    /// The DOCK PREVIEW's rail is `min(dockRailMax, minDimension · dockRailFraction)` — the band the
    /// user sees, which is deliberately NOT the gutter that resolved the dock.
    ///
    /// Both terms are LARGER than the gutter's — the fraction exactly twice (0.12 vs 0.06), the cap
    /// by less (48 vs 28) — and that is the affordance rather than an accident: the gutter is a HIT
    /// band aimed at by a cursor already travelling, so it can be thin, while the rail is a PROMISE
    /// about a full-span column that has to read at a glance over a whole pane of terminal text.
    /// The two pairs were four unnamed literals in two files until docs/56 increment 56c, which is
    /// how a relationship this direct went unstated for as long as it did.
    ///
    /// Keeping them separate is also what stops the preview from lying the other way: a rail drawn
    /// AT the gutter's width would show a 28pt sliver for an op that takes a whole column.
    package static let dockRailFraction: CGFloat = 0.12
    package static let dockRailMax: CGFloat = 48

    /// The RE-SPLIT preview's seam bar — the would-be new divider, drawn along the slab's inner
    /// edge. A dimension rather than a token because the token ladder (`Slate.Metric`) sits ABOVE
    /// `SlopDeskClientCore` and cannot be named from here; it is deliberately a step over the
    /// divider's own dragging width, since this bar is a one-second promise about where a seam will
    /// land rather than the seam itself.
    package static let resplitSeamThickness: CGFloat = 3
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

    // MARK: - The preview's rects (the same round trip, run backwards)

    /// The drop-side HALF of `rect` for the re-split slab — the pane the target is about to become.
    ///
    /// Half, and not ``PaneDropMetrics/edgeBandFraction``'s 30 %, on purpose: the band is where you
    /// AIM and the half is what you GET. A slab drawn at the band's width would preview a 30/70
    /// split that the tree op does not perform.
    package static func slabRect(in rect: CGRect, edge: PaneDropEdge) -> CGRect {
        switch edge {
        case .left:
            CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right:
            CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top:
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom:
            CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    /// The seam bar's size — ``PaneDropMetrics/resplitSeamThickness`` along the slab's inner edge,
    /// the CROSS axis spanning that edge in full. A seam short of its own edge would read as a
    /// handle rather than as a divider.
    package static func seamSize(_ slab: CGRect, edge: PaneDropEdge) -> CGSize {
        switch edge {
        case .left,
             .right:
            CGSize(width: PaneDropMetrics.resplitSeamThickness, height: slab.height)
        case .top,
             .bottom:
            CGSize(width: slab.width, height: PaneDropMetrics.resplitSeamThickness)
        }
    }

    /// The seam bar's centre — on the slab's INNER boundary, the side facing the rest of the target.
    /// It is the mirror of ``slabRect(in:edge:)``'s own edge choice, so the two can never place the
    /// slab on one side and its divider on the other.
    package static func seamCenter(_ slab: CGRect, edge: PaneDropEdge) -> CGPoint {
        switch edge {
        case .left:
            CGPoint(x: slab.maxX, y: slab.midY)
        case .right:
            CGPoint(x: slab.minX, y: slab.midY)
        case .top:
            CGPoint(x: slab.midX, y: slab.maxY)
        case .bottom:
            CGPoint(x: slab.midX, y: slab.minY)
        }
    }

    /// The dock rail band along the whole container edge —
    /// `min(dockRailMax, min(w, h) · dockRailFraction)` thick, full span on the cross axis, which is
    /// the shape of the op: a dock makes the pane a full-span column or row on that edge.
    package static func railRect(in container: CGRect, edge: PaneDropEdge) -> CGRect {
        let thickness = Double.minimum(
            Double(PaneDropMetrics.dockRailMax),
            Double.minimum(Double(container.width), Double(container.height))
                * Double(PaneDropMetrics.dockRailFraction),
        )
        let t = CGFloat(thickness)
        switch edge {
        case .left:
            return CGRect(x: container.minX, y: container.minY, width: t, height: container.height)
        case .right:
            return CGRect(x: container.maxX - t, y: container.minY, width: t, height: container.height)
        case .top:
            return CGRect(x: container.minX, y: container.minY, width: container.width, height: t)
        case .bottom:
            return CGRect(x: container.minX, y: container.maxY - t, width: container.width, height: t)
        }
    }
}
