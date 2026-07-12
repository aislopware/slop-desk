import CoreGraphics
import Foundation

// MARK: - SplitTreeRenderModel (the pure render seam for the IDE split view)

/// The **pure** placement model the `SplitTreeView` renders from (docs/42 §"First-test": the
/// "which pane → which rect, zoom → full rect, dividers between adjacent children" headless seam).
/// Given a ``Tab`` (or a ``SplitNode`` + its zoom state) and a bounding `CGRect`, it produces:
///
/// - **`leaves`** — every visible ``PaneID`` paired with its placed `CGRect` (the leaf rects come from
///   ``SplitLayoutSolver`` so the render and ``FocusResolver`` agree exactly), and
/// - **`dividers`** — a thin draggable handle rect between every pair of adjacent siblings of every
///   split, tagged with the owning `splitID`, the LEADING child index, and the split `axis` (so a
///   horizontal split yields a vertical divider the user drags left/right, and vice-versa).
///
/// ### Zoom
/// When the tab names a `zoomedPane` that is a live leaf, the model collapses to that ONE leaf filling
/// the whole bound and **no dividers** (WezTerm `TabInner.zoomed` — render-only; the tree is untouched).
/// The other leaves are NOT in `leaves` — but they ARE still emitted, as ``Layout/hiddenLeaves`` at their
/// un-zoomed rects, so ``Layout/compositorLeaves`` always carries EVERY pane of the tab and the view keeps
/// the siblings MOUNTED at `opacity 0` (the proven no-teardown trick — unmounting them dismantles the
/// libghostty surface / `.remoteGUI` stream and un-zoom repaints from the lossy replay ring).
///
/// Free of SwiftUI; `CGRect`/`CGFloat` math only (the house float idiom: separate `*`+`+`, never
/// `addingProduct`/`fma`; NaN-faithful ordered `Double.maximum`/`Double.minimum`). Headless-unit-tested
/// by `SplitTreeRenderModelTests`.
public enum SplitTreeRenderModel {
    /// A placed leaf: a ``PaneID`` and the rect it occupies (already solver-clamped to `minLeaf`).
    public struct PlacedLeaf: Equatable, Sendable {
        public let id: PaneID
        public let rect: CGRect
        public init(id: PaneID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    /// A draggable divider between two adjacent siblings of a split. `childIndex` is the LEADING child
    /// (the divider sits between `childIndex` and `childIndex + 1`), matching
    /// ``WorkspaceTreeOps/resizeDivider(splitID:leadingChildIndex:delta:in:)``. `axis` is the split's
    /// axis: a `.horizontal` split (side-by-side columns) yields a divider the user drags horizontally;
    /// a `.vertical` split (stacked rows) yields one dragged vertically.
    public struct DividerHandle: Equatable, Sendable {
        public let splitID: SplitNodeID
        public let childIndex: Int
        public let axis: SplitAxis
        public let rect: CGRect
        /// The OWNING split's axis length (points) — the same `rect`-along-axis the solver partitions and
        /// the denominator for the pixel→flex-weight conversion. For a NESTED split this is the nested
        /// split's rect, NOT the full container, so a nested divider tracks the cursor 1:1.
        public let parentSpan: CGFloat
        /// The sum of the owning split's `.flex` weights (computed exactly as the solver does — sum of
        /// `Double.maximum(w,0)` over `.flex` children, falling back to the flex-child count when that sum
        /// is 0). The pixel→weight conversion multiplies by this so a drag moves the seam 1:1 regardless of
        /// how the split was seeded (a 2-pane split seeds `.flex(1)+.flex(1)` ⇒ `flexSum == 2`).
        public let flexSum: CGFloat
        /// The leading child's current `.flex` weight (the child at ``childIndex``) — the ANCHOR a live drag
        /// reads ONCE at drag start, then sets `leadingWeight + Δpx·flexSum/parentSpan` absolutely each frame
        /// (cursor-matched, drift-free; the store clamps it at ``SplitWeight/minWeight`` so the seam stops on
        /// the neighbour). `0` when the leading child is `.fixed` (the divider is not resizable).
        public let leadingWeight: Double
        /// The TRAILING child's current `.flex` weight (the child at ``childIndex` + 1``) — the other half
        /// of the pair the drag clamp reads (`[minWeight, pairSum − minWeight]`), carried so the hover
        /// cursor can tell one-way from two-way movability. `0` when that child is `.fixed`.
        public let trailingWeight: Double
        public init(
            splitID: SplitNodeID,
            childIndex: Int,
            axis: SplitAxis,
            rect: CGRect,
            parentSpan: CGFloat = 0,
            flexSum: CGFloat = 1,
            leadingWeight: Double = 0,
            trailingWeight: Double = 0,
        ) {
            self.splitID = splitID
            self.childIndex = childIndex
            self.axis = axis
            self.rect = rect
            self.parentSpan = parentSpan
            self.flexSum = flexSum
            self.leadingWeight = leadingWeight
            self.trailingWeight = trailingWeight
        }

        /// The pixel floor each pane keeps along THIS divider's axis — the solver's declared minimum
        /// leaf (``SplitLayoutSolver/defaultMinLeaf``): width for a column seam, height for a row seam.
        /// One source of truth: the drag clamp stopping here is what keeps the render-time floor from
        /// ever overlapping neighbouring panes.
        public var axisMinExtent: CGFloat {
            axis == .horizontal
                ? SplitLayoutSolver.defaultMinLeaf.width
                : SplitLayoutSolver.defaultMinLeaf.height
        }

        /// A child's current on-screen extent along the split axis (`weight / flexSum · parentSpan` —
        /// the solver's flex share, ignoring `.fixed` bands exactly like the drag's pixel→weight
        /// conversion). `0` for an unknown span (a handle built without geometry).
        private func extent(ofWeight weight: Double) -> CGFloat {
            guard parentSpan > 0, flexSum > 0 else { return 0 }
            return CGFloat(weight) / flexSum * parentSpan
        }

        /// Whether the divider can move TOWARD the leading child (left for a column seam, up for a row
        /// seam) — shrinking the leading child, growing the trailing one. Dead once the leading child
        /// sits at its ``axisMinExtent`` pixel floor (the live drag's clamp,
        /// ``clampedLeadingWeight(_:)``); a `.fixed` neighbour (weight sentinel `0`) kills it too.
        /// The half-point slack absorbs float residue from repeated drags — a pane parked AT the floor
        /// must read as immovable, not "movable by 1e-13 px". A handle without geometry (span 0) falls
        /// back to the weight-domain floor the store enforces.
        public var canMoveTowardLeading: Bool {
            guard trailingWeight > 0, leadingWeight > 0 else { return false }
            guard parentSpan > 0 else { return leadingWeight > SplitWeight.minWeight + 0.0005 }
            return extent(ofWeight: leadingWeight) > axisMinExtent + 0.5
        }

        /// The mirror of ``canMoveTowardLeading``: movable toward the TRAILING child (right/down),
        /// which shrinks the trailing child — dead once IT sits at the pixel floor.
        public var canMoveTowardTrailing: Bool {
            guard leadingWeight > 0, trailingWeight > 0 else { return false }
            guard parentSpan > 0 else { return trailingWeight > SplitWeight.minWeight + 0.0005 }
            return extent(ofWeight: trailingWeight) > axisMinExtent + 0.5
        }

        /// Clamp a live-drag's proposed leading weight so the pair keeps its ``axisMinExtent`` pixel
        /// floor — the missing half of the resize contract: the store's weight-domain floor
        /// (``SplitWeight/minWeight``) is RELATIVE, so on a wide parent it let a drag squash a pane
        /// to an invisible sliver (the solver then floors the RENDERED size and the neighbour paints
        /// over it). Sum-preserving like the store clamp; the pixel floor never drops below the
        /// weight floor.
        ///
        /// The bounds BRACKET the current weight (`min(floor, current) … max(pairFloor, current)`),
        /// so a pair too tight to grant both floors still behaves: a side already under the floor
        /// can only be GROWN — the drag works toward balance, never past it — and a pair with both
        /// sides under is frozen. This is exactly the freedom ``canMoveTowardLeading`` /
        /// ``canMoveTowardTrailing`` report, so the cursor and the gesture always agree. An unknown
        /// span (handle built without geometry) passes through — the store's weight floor still
        /// applies.
        public func clampedLeadingWeight(_ proposed: Double) -> Double {
            guard parentSpan > 0, flexSum > 0 else { return proposed }
            let pairSum = leadingWeight + trailingWeight
            let floorWeight = Double.maximum(
                Double(axisMinExtent) / Double(parentSpan) * Double(flexSum),
                SplitWeight.minWeight,
            )
            let lower = Double.minimum(floorWeight, leadingWeight)
            let upper = Double.maximum(pairSum - floorWeight, leadingWeight)
            return Double.minimum(Double.maximum(proposed, lower), upper)
        }

        /// A **stable** SwiftUI identity for the handle — its STRUCTURAL position in the tree
        /// `(splitID, childIndex, axis)`, INDEPENDENT of the live `rect`/`leadingWeight`. A `ForEach`
        /// rendering the dividers MUST key on this, NOT `\.self`: `DividerHandle`'s synthesized `==`
        /// includes `rect`+`leadingWeight`, which change on EVERY live-drag frame, so a `\.self` id changes
        /// every frame → SwiftUI tears down + recreates the divider view mid-drag and CANCELS the in-flight
        /// resize gesture (the drag stalls partway and fires its release early, so the final
        /// reflow never lands). Keyed on `key`, the view keeps its identity and the gesture tracks to the
        /// clamp. There is at most one divider per `(split, leading-index)`, so this is unique per layout.
        public struct Key: Hashable, Sendable {
            public let splitID: SplitNodeID
            public let childIndex: Int
            public let axis: SplitAxis
        }

        /// The stable identity key (see ``Key``). Use this for `ForEach`/`id:` — never `\.self`.
        public var key: Key { Key(splitID: splitID, childIndex: childIndex, axis: axis) }
    }

    /// One placed leaf tagged with its zoom-visibility — the unit the SINGLE-`ForEach` compositor iterates
    /// so a pane's SwiftUI identity (and its hosted terminal / `.remoteGUI` video surface) survives the
    /// zoom hidden↔visible flip within ONE keyed collection (`.id` dedups only within one `ForEach`).
    public struct CompositorLeaf: Equatable, Sendable {
        public let leaf: PlacedLeaf
        /// ZOOM-hidden: the pane is a sibling of the zoomed leaf, kept MOUNTED (the view renders it at
        /// `opacity 0`, no hit-testing) at its un-zoomed rect so its surface survives the zoom toggle —
        /// exactly the keep-all-tabs-mounted trick, applied per pane. `false` for every visible leaf.
        public let isHidden: Bool
        public init(leaf: PlacedLeaf, isHidden: Bool = false) {
            self.leaf = leaf
            self.isHidden = isHidden
        }

        /// The pane identity the compositor `ForEach` keys on — STABLE across the zoom hidden↔visible flip
        /// (one keyed collection, no teardown).
        public var id: PaneID { leaf.id }
    }

    /// The full render layout: the visible tiled leaves + their dividers.
    /// `dividers` is empty for a single-leaf or zoomed tab.
    public struct Layout: Equatable, Sendable {
        public let leaves: [PlacedLeaf]
        public let dividers: [DividerHandle]
        /// The ZOOM-hidden leaves: while a zoom is active, every non-zoomed pane lands here at its
        /// un-zoomed rect, flagged `isHidden` — so ``compositorLeaves`` still carries the FULL pane set and
        /// the view keeps the siblings mounted at `opacity 0` (never unmounted → the libghostty surface /
        /// video stream survives the zoom toggle, and un-zoom is a pure visibility flip, no lossy
        /// ring-replay). Empty while un-zoomed, so the tiled path is byte-identical.
        public let hiddenLeaves: [CompositorLeaf]
        public init(
            leaves: [PlacedLeaf],
            dividers: [DividerHandle],
            hiddenLeaves: [CompositorLeaf] = [],
        ) {
            self.leaves = leaves
            self.dividers = dividers
            self.hiddenLeaves = hiddenLeaves
        }

        public static let empty = Self(leaves: [], dividers: [])

        /// The tiled (+ zoom-hidden) leaves as ONE ordered, `PaneID`-keyed sequence (visible leaves first;
        /// hidden leaves trail — their order is irrelevant at `opacity 0`). The compositor renders EVERY
        /// pane from this single `ForEach` so the zoom hidden↔visible flip stays within one keyed
        /// collection and the pane's hosted surface is never torn down. A pane is in
        /// EXACTLY one of `leaves` / `hiddenLeaves`, so each `PaneID` appears exactly once here.
        public var compositorLeaves: [CompositorLeaf] {
            leaves.map { CompositorLeaf(leaf: $0) } + hiddenLeaves
        }
    }

    /// The on-screen thickness of a divider handle's hit/draw band, centered on the seam between two
    /// siblings. A comfortable trackpad target; the visible hairline can be drawn thinner inside it.
    /// (8pt was too thin to reliably grab — bumped to a comfortable 16pt hit band; the drawn hairline
    /// stays 1.5pt so the seam still looks crisp.)
    public static let dividerThickness: CGFloat = 16

    // MARK: - Entry points

    /// The layout for `tab` solved into `bounds` — honors `tab.zoomedPane` (zoom → one full-bounds leaf,
    /// no dividers).
    public static func layout(
        for tab: Tab,
        in bounds: CGRect,
        minLeaf: CGSize = SplitLayoutSolver.defaultMinLeaf,
        dividerThickness: CGFloat = Self.dividerThickness,
    ) -> Layout {
        layout(
            root: tab.root,
            zoomedPane: tab.zoomedPane,
            in: bounds,
            minLeaf: minLeaf,
            dividerThickness: dividerThickness,
        )
    }

    /// The layout for a bare `root` + optional `zoomedPane` solved into `bounds`. Total: a finite bound
    /// yields finite rects for exactly the visible leaves.
    public static func layout(
        root: SplitNode,
        zoomedPane: PaneID?,
        in bounds: CGRect,
        minLeaf: CGSize = SplitLayoutSolver.defaultMinLeaf,
        dividerThickness: CGFloat = Self.dividerThickness,
    ) -> Layout {
        // Zoom: a single VISIBLE leaf fills the whole bound, no dividers. Only honor a zoom that names a
        // leaf that actually exists in the tree (a stale zoom id falls through to the normal tiled layout).
        // The siblings are NOT dropped: they ride `hiddenLeaves` at their un-zoomed solver rects so the
        // view keeps them mounted (opacity 0, no reflow) — a zoom is a visibility/geometry change, never a
        // teardown (the surfaces + streams survive, un-zoom needs no lossy ring-replay).
        if isZoomActive(root: root, zoomedPane: zoomedPane), let zoomed = zoomedPane {
            let solved = SplitLayoutSolver.solve(root, in: bounds, minLeaf: minLeaf)
            let hidden = root.allPaneIDs().filter { $0 != zoomed }.compactMap { id in
                solved[id].map { CompositorLeaf(leaf: PlacedLeaf(id: id, rect: $0), isHidden: true) }
            }
            return Layout(leaves: [PlacedLeaf(id: zoomed, rect: bounds)], dividers: [], hiddenLeaves: hidden)
        }

        // Leaves come from the SOLVER so the render and FocusResolver agree exactly. Ordered by the tree's
        // deterministic pre-order DFS so the mount order is stable.
        let solved = SplitLayoutSolver.solve(root, in: bounds, minLeaf: minLeaf)
        let placed = root.allPaneIDs().compactMap { id in
            solved[id].map { PlacedLeaf(id: id, rect: $0) }
        }

        // Dividers come from an UN-clamped partition descent (the seam between two siblings is where the
        // partition cut falls, regardless of the per-leaf min clamp) so a handle always sits on the visible
        // boundary.
        var dividers: [DividerHandle] = []
        collectDividers(root, in: bounds, thickness: dividerThickness, into: &dividers)
        return Layout(leaves: placed, dividers: dividers)
    }

    /// Whether a zoom is in effect: `zoomedPane` is non-nil AND names a leaf that actually lives in `root`
    /// (a stale zoom id is ignored → normal tiled layout). The SINGLE source of truth for "is the tab
    /// zoomed".
    static func isZoomActive(root: SplitNode, zoomedPane: PaneID?) -> Bool {
        guard let zoomed = zoomedPane else { return false }
        return root.contains(zoomed)
    }

    // MARK: - Divider descent (un-clamped partition → handle rects)

    private static func collectDividers(
        _ node: SplitNode,
        in rect: CGRect,
        thickness: CGFloat,
        into out: inout [DividerHandle],
    ) {
        switch node {
        case .leaf:
            return
        case let .split(id, axis, children):
            guard !children.isEmpty else { return }
            // Partition `rect` along `axis` by the children's weights — the SAME extents the solver uses
            // (un-clamped) so a divider sits exactly on a sibling seam.
            let parentSpan = axisLength(of: rect, axis: axis)
            let extents = SplitLayoutSolver.extents(for: children, total: parentSpan)
            // The flex-weight sum used by the pixel→weight conversion — mirrors `SplitLayoutSolver.extents`
            // (sum of `Double.maximum(w,0)` over `.flex` children; fall back to the flex-child COUNT when
            // that sum is 0, matching the solver's all-zero-flex equal-split branch).
            let flexSum = dividerFlexSum(for: children)
            var cursor = axisOrigin(of: rect, axis: axis)
            var childRects: [CGRect] = []
            childRects.reserveCapacity(children.count)
            for extent in extents {
                let childRect = subRect(of: rect, axis: axis, origin: cursor, extent: extent)
                childRects.append(childRect)
                cursor += extent
            }
            // A handle band centered on each interior seam (between child i and i+1).
            for i in 0..<(children.count - 1) {
                let seam = trailingEdge(of: childRects[i], axis: axis)
                // The pair's flex weights: leading is the live-drag anchor, both feed the hover cursor's
                // movability; 0 for a `.fixed` (unresizable) side.
                let leadingWeight: Double = if case let .flex(w) = children[i].weight { w } else { 0 }
                let trailingWeight: Double = if case let .flex(w) = children[i + 1].weight { w } else { 0 }
                out.append(DividerHandle(
                    splitID: id,
                    childIndex: i,
                    axis: axis,
                    rect: handleRect(at: seam, axis: axis, span: rect, thickness: thickness),
                    parentSpan: parentSpan,
                    flexSum: flexSum,
                    leadingWeight: leadingWeight,
                    trailingWeight: trailingWeight,
                ))
            }
            // Recurse into the children for nested splits.
            for (child, childRect) in zip(children, childRects) {
                collectDividers(child.node, in: childRect, thickness: thickness, into: &out)
            }
        }
    }

    /// The flex-weight sum of a split's children for the pixel→weight conversion — the SAME quantity
    /// `SplitLayoutSolver.extents` divides by: the sum of `Double.maximum(w,0)` over `.flex` children, or
    /// the flex-child COUNT when that sum is 0 (the solver's all-zero-flex equal-split fallback). Returns 1
    /// when there are no flex children at all (no seam to drag in that degenerate case).
    private static func dividerFlexSum(for children: [WeightedChild]) -> CGFloat {
        var sum = 0.0
        var count = 0
        for child in children {
            if case let .flex(w) = child.weight {
                sum += Double.maximum(w, 0)
                count += 1
            }
        }
        if sum > 0 { return CGFloat(sum) }
        if count > 0 { return CGFloat(count) }
        return 1
    }

    // MARK: - Axis-aware helpers (mirror the solver's geometry)

    private static func axisLength(of rect: CGRect, axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.width
        case .vertical: rect.height
        }
    }

    private static func axisOrigin(of rect: CGRect, axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.minX
        case .vertical: rect.minY
        }
    }

    private static func subRect(of rect: CGRect, axis: SplitAxis, origin: CGFloat, extent: CGFloat) -> CGRect {
        switch axis {
        case .horizontal:
            CGRect(x: origin, y: rect.minY, width: extent, height: rect.height)
        case .vertical:
            CGRect(x: rect.minX, y: origin, width: rect.width, height: extent)
        }
    }

    /// The coordinate of `rect`'s trailing edge along `axis` (`horizontal` → maxX, `vertical` → maxY) —
    /// the seam shared with the next sibling.
    private static func trailingEdge(of rect: CGRect, axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.maxX
        case .vertical: rect.maxY
        }
    }

    /// A divider handle rect of `thickness` centered on the seam coordinate `seam`, spanning the cross-axis
    /// of `span` (the parent rect). A horizontal split's seam is a vertical band (full height of the
    /// parent); a vertical split's seam is a horizontal band (full width).
    private static func handleRect(at seam: CGFloat, axis: SplitAxis, span: CGRect, thickness: CGFloat) -> CGRect {
        let half = thickness / 2
        switch axis {
        case .horizontal:
            return CGRect(x: seam - half, y: span.minY, width: thickness, height: span.height)
        case .vertical:
            return CGRect(x: span.minX, y: seam - half, width: span.width, height: thickness)
        }
    }
}
