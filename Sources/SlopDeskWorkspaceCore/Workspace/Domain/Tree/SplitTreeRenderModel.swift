import CoreGraphics
import SlopDeskWorkspaceModel

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
/// Both halves are the crate's (`rust/slopdesk-workspace`'s `split_layout`) and cross as ONE walk of
/// the tree: the tiles and the seams come out of the same partition, which is what keeps a handle on
/// the edge it drags rather than a pixel off it.
///
/// ### Zoom
/// When the tab names a `zoomedPane` that is a live leaf, the model collapses to that ONE leaf filling
/// the whole bound and **no dividers** (WezTerm `TabInner.zoomed` — render-only; the tree is untouched).
/// The other leaves are NOT in `leaves` — but they ARE still emitted, as ``Layout/hiddenLeaves`` at their
/// un-zoomed rects, so ``Layout/compositorLeaves`` always carries EVERY pane of the tab and the view keeps
/// the siblings MOUNTED at `opacity 0` (the proven no-teardown trick — unmounting them dismantles the
/// libghostty surface / video stream and un-zoom repaints from the lossy replay ring).
///
/// Free of SwiftUI. Headless-unit-tested by `SplitTreeRenderModelTests`.
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

    /// A draggable divider between two adjacent siblings of a split — the crate's seam, carried
    /// verbatim. See ``SplitDividerHandle``.
    public typealias DividerHandle = SplitDividerHandle

    /// One placed leaf tagged with its zoom-visibility — the unit the SINGLE-`ForEach` compositor iterates
    /// so a pane's SwiftUI identity (and its hosted terminal / video surface) survives the
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
    /// siblings — the crate's, so the band the person has to grab is one number.
    public static let dividerThickness = SplitLayoutSolver.dividerThickness

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
        return Layout(
            leaves: placed,
            dividers: SplitLayoutSolver.dividers(root, in: bounds, thickness: dividerThickness),
        )
    }

    /// Whether a zoom is in effect: `zoomedPane` is non-nil AND names a leaf that actually lives in `root`
    /// (a stale zoom id is ignored → normal tiled layout). The SINGLE source of truth for "is the tab
    /// zoomed".
    static func isZoomActive(root: SplitNode, zoomedPane: PaneID?) -> Bool {
        guard let zoomed = zoomedPane else { return false }
        return root.contains(zoomed)
    }
}
