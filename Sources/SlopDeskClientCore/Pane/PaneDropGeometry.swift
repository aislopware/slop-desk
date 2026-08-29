// PaneDropGeometry — the FACE over the rect math a drop resolves through, and the six numbers that
// tune it. The rules themselves are `slopdesk_workspace::pane_drop`; this file is the door.
//
// Two paths ask these questions and they must never answer differently: the canvas compositor's LIVE
// in-tab resolution (a swap, a re-split, a dock, with the dragged pane's own rect excluded) and
// ``PaneDragResolver``'s cross-window INSERT resolution (a satellite drag has no live view to resolve
// in, and no source pane in this tab to exclude). The PREVIEW's rects are asked twice too, and that
// pair is what finally forced the move to Rust: `slabRect` / `seamSize` / `seamCenter` / `railRect`
// are drawn by `SlopDeskMacUI` in AppKit and by `SlopDeskPhoneUI` in SwiftUI, from two files that
// had each written "pure rect math" over their own reading of it. Two frameworks re-deriving a
// slab's half by eye is how one half draws a promise the shared resolver never commits — and now
// neither half can, because there is one implementation and it is not in this language.
//
// WHAT DID NOT GO. ``leaf(at:in:excluding:)`` stays in Swift, and deliberately: it takes
// `SplitTreeRenderModel.PlacedLeaf`s and hands back a `PaneID`, so porting it would carry an
// IDENTITY across the ABI and back — a copy made only to be compared with the one it came from,
// which is exactly what `rust/slopdesk-devicepanel`'s charter refuses. It is also a linear scan
// with no arithmetic in it: there is no rule to disagree about, only an order, and the order is
// already the caller's.
//
// The metrics come through a door rather than being re-declared here for the same reason the rects
// did. A `static let 0.30` in this file would be a SECOND place the affordance is written down,
// free to drift from the Rust the resolver actually runs, and nothing would fail when it did.

import CoreGraphics
import CSlopDeskFFI
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// Tunable drop-zone geometry (a UI affordance, deliberately NOT env flags). The hovered target pane
/// is divided into a central SWAP box and four edge bands; the whole container gets an outer DOCK
/// gutter.
///
/// Every value is read from `slopdesk_pane_drop_metric` at first use — the numbers live in Rust
/// beside the rules that consume them.
package enum PaneDropMetrics {
    /// Each edge band is this fraction of the target's width/height (so the central swap box is the
    /// middle `1 - 2·edgeBandFraction` — 40% at 0.30). A generous centre keeps the common swap easy;
    /// 30% bands stay aimable on small panes.
    package static let edgeBandFraction = metric(SLOPDESK_PANE_DROP_METRIC_EDGE_BAND_FRACTION)
    /// The container outer DOCK gutter is `min(containerGutterMax, minDimension · containerGutterFraction)`.
    package static let containerGutterFraction =
        metric(SLOPDESK_PANE_DROP_METRIC_CONTAINER_GUTTER_FRACTION)
    package static let containerGutterMax = metric(SLOPDESK_PANE_DROP_METRIC_CONTAINER_GUTTER_MAX)

    /// The DOCK PREVIEW's rail is `min(dockRailMax, minDimension · dockRailFraction)` — the band the
    /// user sees, which is deliberately NOT the gutter that resolved the dock.
    ///
    /// Both terms are LARGER than the gutter's — the fraction exactly twice, the cap by less — and
    /// that is the affordance rather than an accident: the gutter is a HIT band aimed at by a cursor
    /// already travelling, so it can be thin, while the rail is a PROMISE about a full-span column
    /// that has to read at a glance over a whole pane of terminal text. Keeping them separate is
    /// also what stops the preview from lying the other way: a rail drawn AT the gutter's width
    /// would show a sliver for an op that takes a whole column.
    package static let dockRailFraction = metric(SLOPDESK_PANE_DROP_METRIC_DOCK_RAIL_FRACTION)
    package static let dockRailMax = metric(SLOPDESK_PANE_DROP_METRIC_DOCK_RAIL_MAX)

    /// The RE-SPLIT preview's seam bar — the would-be new divider, drawn along the slab's inner
    /// edge. A dimension rather than a token because every other figure in this file is one and they
    /// are decided together in Rust — NOT because the ladder is out of reach. ⚠️ This comment used to
    /// say `Slate.Metric` "sits ABOVE `SlopDeskClientCore` and cannot be named from here", which is
    /// false in the plainest way: `Package.swift:475` lists `SlopDeskSlate` among this target's
    /// dependencies, and `Pane/DecorationDivider.swift` spends `Slate.Metric.space2` directly. The
    /// same sentence was written into `Pane/GuiLeafChromeLayout.swift` and
    /// `Overlays/OverlayCardLayout.swift`, and in the first it cost a `no-cross-target-clone` red —
    /// a wrong fact in a header propagates further than a wrong line of code, because the next
    /// author reads it as settled. It is deliberately a step over the
    /// divider's own dragging width, since this bar is a one-second promise about where a seam will
    /// land rather than the seam itself.
    package static let resplitSeamThickness =
        metric(SLOPDESK_PANE_DROP_METRIC_RESPLIT_SEAM_THICKNESS)

    private static func metric(_ code: UInt32) -> CGFloat {
        CGFloat(slopdesk_pane_drop_metric(code))
    }
}

/// The pure rect math behind drop-zone resolution — shared between the canvas's live in-canvas
/// resolution and ``PaneDragResolver``'s cross-window INSERT resolution, so the two paths can never
/// disagree on what a gutter or an edge band is.
package enum PaneDropGeometry {
    /// The first leaf (in the given order) whose rect contains `location`, excluding the dragged
    /// `source` (`nil` for an INSERT drag — a satellite drop has no source pane to exclude). Iterating
    /// the ORDERED leaves (not an unordered dict) keeps the resolved target deterministic if a
    /// min-clamped, over-subscribed layout ever overlaps two rects.
    ///
    /// The one rule here that stayed in Swift, because it carries a `PaneID` rather than a number.
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
        PaneDropEdge(code: slopdesk_pane_drop_container_edge(
            SlopDeskVideoPoint(x: Double(location.x), y: Double(location.y)),
            .init(container),
            .init(sourceRect ?? .zero),
            sourceRect != nil,
        ))
    }

    /// Whether `rect` already fully spans the container `edge` (so docking the pane there would be a no-op).
    package static func sourceSpans(_ rect: CGRect, _ edge: PaneDropEdge, _ container: CGRect) -> Bool {
        slopdesk_pane_drop_source_spans(.init(rect), edge.code, .init(container))
    }

    /// The edge band the cursor (normalized `u`,`v` in the target) has penetrated deepest. With the
    /// MOVE band (< 0.5) it is called only when the cursor is NOT in the centre box, so at least one
    /// penetration is positive; band 0.5 (the INSERT drag) maps every interior point to its nearest
    /// edge. Exact tie → a vertical (left/right) edge.
    package static func dominantEdge(u: CGFloat, v: CGFloat, band: CGFloat) -> PaneDropEdge {
        PaneDropEdge(
            code: slopdesk_pane_drop_dominant_edge(Double(u), Double(v), Double(band)),
        ) ?? .left
    }

    // MARK: - The preview's rects (the same round trip, run backwards)

    /// The drop-side HALF of `rect` for the re-split slab — the pane the target is about to become.
    ///
    /// Half, and not ``PaneDropMetrics/edgeBandFraction``'s 30 %, on purpose: the band is where you
    /// AIM and the half is what you GET. A slab drawn at the band's width would preview a 30/70
    /// split that the tree op does not perform.
    package static func slabRect(in rect: CGRect, edge: PaneDropEdge) -> CGRect {
        CGRect(slopdesk_pane_drop_slab_rect(.init(rect), edge.code))
    }

    /// The seam bar's size — ``PaneDropMetrics/resplitSeamThickness`` along the slab's inner edge,
    /// the CROSS axis spanning that edge in full. A seam short of its own edge would read as a
    /// handle rather than as a divider.
    package static func seamSize(_ slab: CGRect, edge: PaneDropEdge) -> CGSize {
        let size = slopdesk_pane_drop_seam_size(.init(slab), edge.code)
        return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
    }

    /// The seam bar's centre — on the slab's INNER boundary, the side facing the rest of the target.
    /// It is the mirror of ``slabRect(in:edge:)``'s own edge choice, so the two can never place the
    /// slab on one side and its divider on the other.
    package static func seamCenter(_ slab: CGRect, edge: PaneDropEdge) -> CGPoint {
        let point = slopdesk_pane_drop_seam_center(.init(slab), edge.code)
        return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
    }

    /// The dock rail band along the whole container edge —
    /// `min(dockRailMax, min(w, h) · dockRailFraction)` thick, full span on the cross axis, which is
    /// the shape of the op: a dock makes the pane a full-span column or row on that edge.
    package static func railRect(in container: CGRect, edge: PaneDropEdge) -> CGRect {
        CGRect(slopdesk_pane_drop_rail_rect(.init(container), edge.code))
    }
}

/// The edge's code across the ABI.
///
/// A `String`-raw enum on this side and a `uint32_t` on that one, because the two are answering
/// different needs: the Swift raw value is what a workspace file and a menu item read, and the code
/// is what a door speaks. `nil` from the initializer is the door's fifth answer — no edge at all —
/// which only ``PaneDropGeometry/containerEdge(at:container:sourceRect:)`` can produce.
private extension PaneDropEdge {
    var code: UInt32 {
        switch self {
        case .left: SLOPDESK_PANE_DROP_EDGE_LEFT
        case .right: SLOPDESK_PANE_DROP_EDGE_RIGHT
        case .top: SLOPDESK_PANE_DROP_EDGE_TOP
        case .bottom: SLOPDESK_PANE_DROP_EDGE_BOTTOM
        }
    }

    init?(code: UInt32) {
        switch code {
        case SLOPDESK_PANE_DROP_EDGE_LEFT: self = .left
        case SLOPDESK_PANE_DROP_EDGE_RIGHT: self = .right
        case SLOPDESK_PANE_DROP_EDGE_TOP: self = .top
        case SLOPDESK_PANE_DROP_EDGE_BOTTOM: self = .bottom
        default: return nil
        }
    }
}

private extension SlopDeskVideoRect {
    /// A `CGRect` in the door's words. The vocabulary is the video path's because the device panel
    /// already borrows it, and a second struct with the same four fields would buy nothing.
    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height),
        )
    }
}

private extension CGRect {
    init(_ rect: SlopDeskVideoRect) {
        self.init(
            x: CGFloat(rect.x), y: CGFloat(rect.y),
            width: CGFloat(rect.width), height: CGFloat(rect.height),
        )
    }
}
