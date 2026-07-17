// PaneMoveAffordance — the "grab the pane and move it" affordance.
//
// A short drag handle (a `-` pill) is revealed near the TOP of a pane on hover; you grab it to move the
// pane. Adapted to the remote-app rule: the drag mutates NOTHING in the store — it only
// updates a view-local `PaneMoveDrag` that drives an overlay. Only on release does `SplitContainer` commit
// exactly ONE store op, so the layout / terminal-grid / remote-window redraw fires once, not per drag frame.
//
// The drop is not just a swap. The cursor's position over the canvas resolves to a `PaneDropZone`:
//   • CENTER of a target pane  → SWAP the two panes (the original behaviour).
//   • an EDGE band of a target  → RE-SPLIT: the dragged pane becomes a new column (left/right) or row
//     (top/bottom) beside the target — dropping a side-by-side pair on each other's TOP/BOTTOM edge turns
//     the side-by-side (`.horizontal`) split into a stacked (`.vertical`) one — the re-orientation between
//     side-by-side and stacked layout the user asked for.
//   • the CONTAINER's outer gutter → DOCK: the pane becomes a full-span column/row on that whole edge.
// Each zone draws a visually distinct preview so the committed action reads before release.
//
// Hit-test footprint: the handle view fills its leaf but only a SHORT top strip is hit-testable (a `Spacer`
// fills the rest and passes clicks through to the terminal below it in the ZStack). The strip senses hover
// (to reveal the pill) and owns the drag gesture. SYSTEM / design-token colours only.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// The shared coordinate space the move gesture reports its location in — `SplitContainer` names its
/// compositor ZStack with this so a gesture location lines up 1:1 with the solver's leaf rects.
enum PaneMoveSpace {
    static let name = "slopdesk.splitspace"
}

/// Tunable drop-zone geometry (a UI affordance, deliberately NOT env flags). The hovered target pane is
/// divided into a central SWAP box and four edge bands; the whole container gets an outer DOCK gutter.
enum PaneDropMetrics {
    /// Each edge band is this fraction of the target's width/height (so the central swap box is the middle
    /// `1 - 2·edgeBandFraction` — 40% at 0.30). A generous centre keeps the common swap easy; 30% bands stay
    /// aimable on small panes.
    static let edgeBandFraction: CGFloat = 0.30
    /// The container outer DOCK gutter is `min(containerGutterMax, minDimension · containerGutterFraction)`.
    static let containerGutterFraction: CGFloat = 0.06
    static let containerGutterMax: CGFloat = 28
}

/// The pure rect math behind drop-zone resolution — shared between `SplitContainer`'s live in-canvas
/// resolution and ``PaneDragResolver``'s cross-window INSERT resolution (a satellite drag has no live
/// view to resolve in), so the two paths can never disagree on what a gutter or an edge band is.
enum PaneDropGeometry {
    /// The first leaf (in the given order) whose rect contains `location`, excluding the dragged
    /// `source` (`nil` for an INSERT drag — a satellite drop has no source pane to exclude). Iterating
    /// the ORDERED leaves (not an unordered dict) keeps the resolved target deterministic if a
    /// min-clamped, over-subscribed layout ever overlaps two rects.
    static func leaf(
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
    static func containerEdge(
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
    static func sourceSpans(_ rect: CGRect, _ edge: PaneDropEdge, _ container: CGRect) -> Bool {
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
    static func dominantEdge(u: CGFloat, v: CGFloat, band: CGFloat) -> PaneDropEdge {
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

/// The action a release at the current cursor location would commit (resolved every drag frame, committed
/// once on `.onEnded`). `.none` is a cancel (release commits nothing).
enum PaneDropZone: Equatable {
    case none
    /// Drop in the centre of `target` → exchange the two panes' positions.
    case swap(target: PaneID)
    /// Drop on an `edge` band of `target` → the dragged pane becomes a new column/row beside it.
    case resplit(target: PaneID, edge: PaneDropEdge)
    /// Drop in the container's outer gutter → dock the dragged pane to that whole `edge`.
    case dock(edge: PaneDropEdge)
}

/// View-local move-drag state (held in `SplitContainer`). `zone` is the resolved drop action under the
/// cursor; the overlay previews it and `.onEnded` commits it.
struct PaneMoveDrag: Equatable {
    var source: PaneID
    var location: CGPoint
    var zone: PaneDropZone
}

/// The per-leaf top grab handle. Reveals a `-` pill on hover; the drag reports its live cursor location to
/// `SplitContainer` (which resolves the zone + commits on `.onEnded`).
struct PaneMoveHandle: View {
    /// This leaf's on-screen size (the handle fills it; only the top strip is interactive).
    let leafSize: CGSize
    /// Whether THIS leaf is the one currently being dragged (drives the pill's active styling + cursor).
    let isDragging: Bool
    /// Live drag callbacks — locations are in the `PaneMoveSpace.name` coordinate space.
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    /// A plain tap on the strip focuses the pane (so the top strip is not a focus dead-zone).
    let onTap: () -> Void

    @State private var hovering = false

    /// The grab strip is centred + width-limited so it covers minimal terminal real estate and never
    /// overlaps the side dividers. Short panes get a proportionally smaller strip.
    private var stripWidth: CGFloat { Double.minimum(160, Double.maximum(56, Double(leafSize.width) * 0.4)) }
    /// 14pt strip flush to the leaf's top edge → the pill's centre sits 7pt in, INSIDE the pane's
    /// top padding band. A 3pt inset + 22pt strip would put the pill at ~14pt — over the first line
    /// of terminal text, where it overlaps the pane's content.
    private let stripHeight: CGFloat = 14

    private var revealed: Bool { hovering || isDragging }

    var body: some View {
        VStack(spacing: 0) {
            strip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var strip: some View {
        ZStack {
            Capsule()
                .fill(isDragging ? Slate.State.accent : Slate.Text.tertiary)
                .frame(width: 30, height: 4)
                .opacity(revealed ? 1 : 0)
                .scaleEffect(hovering && !isDragging ? 1.15 : 1)
        }
        .frame(width: stripWidth, height: stripHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        #if os(macOS)
            .pointerStyle(isDragging ? .grabActive : .grabIdle)
        #endif
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(PaneMoveSpace.name))
                    .onChanged { onChanged($0.location) }
                    .onEnded { onEnded($0.location) },
            )
            .onTapGesture { onTap() }
            .animation(Slate.Anim.dividerHover, value: revealed)
    }
}

/// The drag overlay drawn ABOVE the panes while a move is in flight: a zone-specific drop preview, the
/// dashed "lifted" outline on the source, and a ghost chip pinned to the cursor. Purely visual
/// (`allowsHitTesting(false)` at the call site).
struct PaneMoveOverlay: View {
    let drag: PaneMoveDrag
    /// Leaf rects (solver space == `PaneMoveSpace.name`), keyed by pane.
    let frames: [PaneID: CGRect]
    /// The whole compositor bound — the DOCK rail spans its edges.
    let container: CGRect
    /// The dragged pane's title for the ghost chip (falls back to a generic label).
    let sourceTitle: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            zonePreview
            sourceOutline
            ghostChip
                .position(x: drag.location.x, y: drag.location.y)
        }
    }

    // MARK: Zone-specific drop preview

    /// A distinct identity per resolved zone (incl. each re-split EDGE) so a zone change CROSS-FADES rather
    /// than interpolating the half-pane slab's frame across the pane — animating the slab's frame across
    /// edges would sweep a big rectangle around the pane, which reads as heavy; a quick opacity snap stays
    /// out of the way.
    private var zoneKey: String {
        switch drag.zone {
        case .none: "none"
        case let .swap(target): "swap-\(target)"
        case let .resplit(target, edge): "resplit-\(target)-\(edge.rawValue)"
        case let .dock(edge): "dock-\(edge.rawValue)"
        }
    }

    private var zonePreview: some View {
        zoneShape
            .id(zoneKey)
            .transition(.opacity)
    }

    @ViewBuilder
    private var zoneShape: some View {
        switch drag.zone {
        case .none:
            EmptyView()
        case let .swap(target):
            if let rect = frames[target] { Self.washPreview(rect) }
        case let .resplit(target, edge):
            if let rect = frames[target] { Self.slabPreview(in: rect, edge: edge) }
        case let .dock(edge):
            Self.railPreview(in: container, edge: edge)
        }
    }

    // The three zone previews are `static` — kept callable from outside the drag gesture so any
    // future drop overlay draws the SAME visual language (one drop vocabulary).

    /// SWAP / whole-area wash: a wash + border over the WHOLE rect — "this entire area".
    static func washPreview(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
            .fill(Slate.State.accentMuted)
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(Slate.State.accent, lineWidth: 2),
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    /// RE-SPLIT: an accent SLAB over the drop-side HALF of the target, with a bright seam line on the inner
    /// boundary where the new divider lands — the user literally sees a column vs a row form.
    static func slabPreview(in rect: CGRect, edge: PaneDropEdge) -> some View {
        let slab = Self.slabRect(in: rect, edge: edge)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                .fill(Slate.State.accentMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                        .strokeBorder(Slate.State.accent.opacity(0.7), lineWidth: 1.5),
                )
                .frame(width: slab.width, height: slab.height)
                .position(x: slab.midX, y: slab.midY)
            // The seam: a 3pt accent bar on the slab's INNER edge (the would-be new divider).
            Capsule()
                .fill(Slate.State.accent)
                .frame(width: Self.seamSize(slab, edge: edge).width, height: Self.seamSize(slab, edge: edge).height)
                .position(Self.seamCenter(slab, edge: edge))
        }
    }

    /// DOCK: a full-length accent RAIL pinned to the whole container edge — "full span, tab-wide", visually
    /// distinct from the per-pane half-slab.
    static func railPreview(in container: CGRect, edge: PaneDropEdge) -> some View {
        let rail = Self.railRect(in: container, edge: edge)
        return RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
            .fill(Slate.State.accentMuted)
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(Slate.State.accent, lineWidth: 2),
            )
            .frame(width: rail.width, height: rail.height)
            .position(x: rail.midX, y: rail.midY)
    }

    // MARK: Source + cursor chrome

    private var sourceOutline: some View {
        Group {
            if let rect = frames[drag.source] {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(
                        Slate.State.accent.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]),
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private var ghostChip: some View {
        HStack(spacing: 6) {
            Image(systemSymbol: Self.zoneIcon(drag.zone))
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            Text(Self.zoneLabel(drag.zone, title: sourceTitle))
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(drag.zone == .none ? Slate.Text.tertiary : Slate.Text.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Slate.Surface.face)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            drag.zone == .none ? Slate.Text.tertiary.opacity(0.4) : Slate.State.accent,
                            lineWidth: 1,
                        ),
                ),
        )
        .shadow(color: Slate.State.shadow, radius: 8, y: 2)
        .fixedSize()
    }

    // MARK: Geometry helpers (pure rect math)

    /// The drop-side HALF of `rect` for the re-split slab.
    static func slabRect(in rect: CGRect, edge: PaneDropEdge) -> CGRect {
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

    /// The seam bar's size — a thin bar along the slab's INNER edge (cross-axis full length).
    static func seamSize(_ slab: CGRect, edge: PaneDropEdge) -> CGSize {
        switch edge {
        case .left,
             .right:
            CGSize(width: 3, height: slab.height)
        case .top,
             .bottom:
            CGSize(width: slab.width, height: 3)
        }
    }

    /// The seam bar's centre — on the slab's inner boundary (the side facing the rest of the target).
    static func seamCenter(_ slab: CGRect, edge: PaneDropEdge) -> CGPoint {
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

    /// The dock rail band along the whole container edge.
    static func railRect(in container: CGRect, edge: PaneDropEdge) -> CGRect {
        let thickness = Double.minimum(48, Double.minimum(Double(container.width), Double(container.height)) * 0.12)
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

    static func zoneIcon(_ zone: PaneDropZone) -> SFSymbol {
        switch zone {
        case .none: .xmark
        case .swap: .rectangle2Swap
        case let .resplit(_, edge): edge.axis == .horizontal ? .rectangleSplit2x1 : .rectangleSplit1x2
        case let .dock(edge): edge.axis == .horizontal ? .rectangleSplit2x1 : .rectangleSplit1x2
        }
    }

    static func zoneLabel(_ zone: PaneDropZone, title: String?) -> String {
        let name = title ?? "pane"
        switch zone {
        case .none: return "cancel"
        case .swap: return "swap \(name)"
        case let .resplit(_, edge): return "split \(edge.rawValue)"
        case let .dock(edge): return "dock \(edge.rawValue)"
        }
    }
}
#endif
