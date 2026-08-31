// SplitTreeRenderModel — the face over `slopdesk_workspace::split_zoom`, which decides what a split
// tab actually draws once zoom has had its say.
//
// The partition itself was already the crate's (`SplitLayoutSolver` → `split_layout`). What crossed
// here is the layer above it: whether a zoom is IN EFFECT, and what the frame looks like while one
// is. Both were the kind of rule that reads as obvious in a renderer and is not:
//
//   • A zoom naming a pane that has since been closed must be IGNORED. Honouring it collapses the
//     tab onto a pane that does not exist — an empty window with no way out.
//   • The siblings of a zoomed pane are still SOLVED, and still emitted, flagged hidden at their
//     un-zoomed rects. A pane the model stops emitting is a pane the view unmounts, and unmounting
//     one dismantles the terminal surface or the video stream behind it; un-zoom would then
//     repaint from the lossy replay ring. Zoom is a visibility change, never a teardown.
//   • A zoomed tab draws NO seams. That gate lives behind `slopdesk_ws_render_dividers` rather than
//     at the call site, because a renderer that decided it for itself would be a second copy of the
//     zoom verdict, sitting where nobody would look for it when the first copy changed.
//
// The value types stay here — `Layout` / `PlacedLeaf` / `CompositorLeaf` are what each shell's canvas
// reconciles its mounted pane views against (`MacSplitCanvasView.applyPanes` and the phone's
// `SplitCanvasView`), and the dividers (`MacPaneDivider` / `PaneDividerView`) and the drop geometry key on
// them too. The tree crosses as its PRE-ORDER walk, the same one the solver already takes:
// this runs on every layout pass, and a parse plus an allocation per frame is the regression
// `CLAUDE.md` says vetoes a port.

import CoreGraphics
import CSlopDeskFFI
import SlopDeskWorkspaceModel

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

    /// One placed leaf tagged with its zoom-visibility — the unit the canvas's SINGLE reconcile pass
    /// iterates, so a pane's mounted view (and its hosted terminal / video surface) survives the zoom
    /// hidden↔visible flip. The canvas keeps a `[PaneID: view]` map and tears down exactly the ids that
    /// LEFT the list, so a pane that merely changed visibility must never leave it.
    public struct CompositorLeaf: Equatable, Sendable {
        public let leaf: PlacedLeaf
        /// ZOOM-hidden: the pane is a sibling of the zoomed leaf, kept MOUNTED at its un-zoomed rect so its
        /// surface survives the zoom toggle — exactly the keep-all-tabs-mounted trick, applied per pane.
        /// The canvas honors it as `alphaValue = 0` plus an accessibility-hidden flag, deliberately NOT
        /// AppKit's own `isHidden`: a layer-hosting leaf sizes its surface from its own layout pass, and a
        /// truly hidden view stops getting one. `false` for every visible leaf.
        public let isHidden: Bool
        public init(leaf: PlacedLeaf, isHidden: Bool = false) {
            self.leaf = leaf
            self.isHidden = isHidden
        }

        /// The pane identity the canvas's reconcile keys its mounted-view map on — STABLE across the zoom
        /// hidden↔visible flip (one list, one map, no teardown).
        public var id: PaneID { leaf.id }
    }

    /// The full render layout: the visible tiled leaves + their dividers.
    /// `dividers` is empty for a single-leaf or zoomed tab.
    public struct Layout: Equatable, Sendable {
        public let leaves: [PlacedLeaf]
        public let dividers: [DividerHandle]
        /// The ZOOM-hidden leaves: while a zoom is active, every non-zoomed pane lands here at its
        /// un-zoomed rect, flagged `isHidden` — so ``compositorLeaves`` still carries the FULL pane set and
        /// the canvas keeps the siblings mounted at zero alpha (never unmounted → the terminal surface /
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
        /// hidden leaves trail — their order is irrelevant at zero alpha). The canvas reconciles EVERY pane
        /// from this ONE list, so the zoom hidden↔visible flip never removes an id from the wanted set and
        /// the pane's hosted surface is never torn down. A pane is in EXACTLY one of `leaves` /
        /// `hiddenLeaves`, so each `PaneID` appears exactly once here.
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
    /// yields finite rects for exactly the visible leaves, and a walk the crate cannot rebuild yields
    /// ``Layout/empty`` rather than a partial frame.
    ///
    /// TWO crossings, not one: the leaves and the seams come out of the same partition on the far
    /// side, and splitting them keeps each answer a flat array of one `@frozen` C type — a single
    /// door would have needed a tagged union and a second cursor walk to read it back.
    public static func layout(
        root: SplitNode,
        zoomedPane: PaneID?,
        in bounds: CGRect,
        minLeaf: CGSize = SplitLayoutSolver.defaultMinLeaf,
        dividerThickness: CGFloat = Self.dividerThickness,
    ) -> Layout {
        var walk = WsTree.walk(root)
        let rect = SlopDeskWsRect(bounds)
        let zoom = zoomedPane
        return walk.withUnsafeMutableBufferPointer { nodes -> Layout in
            let placed = delivered(count: max(8, nodes.count), SlopDeskWsRenderLeaf()) { out, cap in
                slopdesk_ws_render_leaves(
                    nodes.baseAddress, nodes.count, rect,
                    minLeaf.width, minLeaf.height,
                    zoom != nil, zoom?.ffi ?? SlopDeskWsUuid(),
                    out, cap,
                )
            }
            let seams = delivered(count: max(4, nodes.count), SlopDeskWsDivider()) { out, cap in
                slopdesk_ws_render_dividers(
                    nodes.baseAddress, nodes.count, rect, dividerThickness,
                    zoom != nil, zoom?.ffi ?? SlopDeskWsUuid(),
                    out, cap,
                )
            }
            // ONE array crossed, carrying every pane of the tab; the split into visible / hidden is
            // the flag the far side already set, not a second verdict taken here.
            var visible: [PlacedLeaf] = []
            var hidden: [CompositorLeaf] = []
            for item in placed {
                let leaf = PlacedLeaf(id: PaneID(ffi: item.frame.id), rect: item.frame.rect.rect)
                if item.hidden {
                    hidden.append(CompositorLeaf(leaf: leaf, isHidden: true))
                } else {
                    visible.append(leaf)
                }
            }
            return Layout(
                leaves: visible,
                dividers: seams.map(SplitDividerHandle.init(ffi:)),
                hiddenLeaves: hidden,
            )
        }
    }

    /// Whether a zoom is in effect: `zoomedPane` is non-nil AND names a leaf that actually lives in `root`
    /// (a stale zoom id is ignored → normal tiled layout). The SINGLE source of truth for "is the tab
    /// zoomed" — asked of the crate, so it is the same answer the layout above laid the frame out
    /// against rather than a second reading of the same tree.
    static func isZoomActive(root: SplitNode, zoomedPane: PaneID?) -> Bool {
        var walk = WsTree.walk(root)
        return walk.withUnsafeMutableBufferPointer { nodes in
            slopdesk_ws_zoom_is_active(
                nodes.baseAddress, nodes.count,
                zoomedPane != nil, zoomedPane?.ffi ?? SlopDeskWsUuid(),
            )
        }
    }

    /// Reads a `(out, cap) -> needed` array answer with the retry docs/55 §4 describes: guess once,
    /// and ask again at the size the door reported if the guess was short.
    private static func delivered<T>(
        count: Int,
        _ empty: T,
        _ door: (UnsafeMutablePointer<T>?, Int) -> Int,
    ) -> [T] {
        var out = [T](repeating: empty, count: count)
        var needed = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
        if needed > out.count {
            out = [T](repeating: empty, count: needed)
            needed = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
        }
        guard needed <= out.count else { return [] }
        return Array(out[0..<needed])
    }
}
