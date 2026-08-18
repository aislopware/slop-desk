import CoreGraphics
import CSlopDeskFFI

// MARK: - SplitLayoutSolver (the tree → rectangles partition)

/// Turns a ``SplitNode`` into the rectangle each leaf draws in, and the seams the dividers sit on.
///
/// The partition is `rust/slopdesk-workspace`'s `split_layout` (docs/55). What crosses is the tree's
/// PRE-ORDER walk rather than its persisted JSON: both languages already agree on that JSON, and
/// reusing it here would have been two lines — but ``solve(_:in:minLeaf:)`` runs on every layout
/// pass, and a parse plus an allocation per frame is the one kind of regression `CLAUDE.md` says
/// vetoes a port. One array, one pass, no parse; the persisted codec stays what it is for, disk.
public enum SplitLayoutSolver {
    /// The default minimum on-screen size of a leaf. A leaf is never solved smaller than this even
    /// when the bound cannot hold every sibling — the clamp is a FLOOR, so in that pathological case
    /// the rects may exceed the bound rather than collapse a pane to nothing.
    public static let defaultMinLeaf: CGSize = {
        let floor = slopdesk_ws_min_leaf()
        return CGSize(width: floor.x, height: floor.y)
    }()

    /// Solves `root` inside `rect`, returning each leaf ``PaneID``'s rect. `minLeaf` floors every
    /// leaf's width/height. Total: a finite `rect` yields finite rects for exactly
    /// `root.allPaneIDs()`, and a tree the walk cannot rebuild yields none at all.
    public static func solve(
        _ root: SplitNode,
        in rect: CGRect,
        minLeaf: CGSize = Self.defaultMinLeaf,
    ) -> [PaneID: CGRect] {
        var walk = WsTree.walk(root)
        var frames: [PaneID: CGRect] = [:]
        walk.withUnsafeMutableBufferPointer { nodes in
            let empty = SlopDeskWsFrame()
            var out = [SlopDeskWsFrame](repeating: empty, count: max(8, nodes.count))
            var needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_solve_layout(
                    nodes.baseAddress,
                    nodes.count,
                    SlopDeskWsRect(rect),
                    minLeaf.width,
                    minLeaf.height,
                    buffer.baseAddress,
                    buffer.count,
                )
            }
            if needed > out.count {
                out = [SlopDeskWsFrame](repeating: empty, count: needed)
                needed = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_solve_layout(
                        nodes.baseAddress,
                        nodes.count,
                        SlopDeskWsRect(rect),
                        minLeaf.width,
                        minLeaf.height,
                        buffer.baseAddress,
                        buffer.count,
                    )
                }
            }
            guard needed <= out.count else { return }
            for frame in out[0..<needed] {
                frames[PaneID(ffi: frame.id)] = frame.rect.rect
            }
        }
        return frames
    }

    /// The band a divider is drawn and hit with. Wide enough to grab on a trackpad; the hairline
    /// drawn inside it can be thinner.
    public static let dividerThickness = CGFloat(slopdesk_ws_divider_thickness())

    /// Every draggable seam of `root` solved into `rect`, in pre-order.
    ///
    /// The same walk the solve crosses as, answered by the same partition — a seam placed by a
    /// second copy of that partition would sit a pixel off the edge it is supposed to drag.
    public static func dividers(
        _ root: SplitNode,
        in rect: CGRect,
        thickness: CGFloat = Self.dividerThickness,
    ) -> [SplitDividerHandle] {
        var walk = WsTree.walk(root)
        return walk.withUnsafeMutableBufferPointer { nodes -> [SplitDividerHandle] in
            let ask = { (out: inout UnsafeMutableBufferPointer<SlopDeskWsDivider>) in
                slopdesk_ws_dividers(
                    nodes.baseAddress, nodes.count, SlopDeskWsRect(rect), thickness,
                    out.baseAddress, out.count,
                )
            }
            let empty = SlopDeskWsDivider()
            var out = [SlopDeskWsDivider](repeating: empty, count: max(4, nodes.count))
            var needed = out.withUnsafeMutableBufferPointer(ask)
            if needed > out.count {
                out = [SlopDeskWsDivider](repeating: empty, count: needed)
                needed = out.withUnsafeMutableBufferPointer(ask)
            }
            guard needed <= out.count else { return [] }
            return out[0..<needed].map(SplitDividerHandle.init(ffi:))
        }
    }
}

// MARK: - A draggable seam

/// One seam between two adjacent siblings of a split: where the handle is drawn, and everything a
/// DRAG on it needs.
///
/// ``parentSpan`` is the OWNING split's axis length — for a nested split its own rect, not the
/// container's — so the pixel→weight conversion moves the seam 1:1 with the cursor wherever it
/// sits. ``leadingWeight`` is the anchor a live drag reads once at drag start and offsets from;
/// ``trailingWeight`` is the other half of the pair the clamp brackets. A `0` weight is a `.fixed`
/// child, which is not draggable at all.
///
/// The three answers below — both directions' movability and the clamp — are the crate's
/// (`rust/slopdesk-workspace`'s `split_layout`), so the arrow the hover cursor shows and the seam
/// the gesture actually produces read one rule rather than two.
public struct SplitDividerHandle: Equatable, Sendable {
    public let splitID: SplitNodeID
    /// The LEADING child: the seam sits between it and `childIndex + 1`, matching
    /// ``WorkspaceTreeOps/resizeDivider(splitID:leadingChildIndex:delta:in:)``.
    public let childIndex: Int
    /// The owning split's axis: a `.horizontal` split (columns) yields a seam dragged left/right.
    public let axis: SplitAxis
    public let rect: CGRect
    public let parentSpan: CGFloat
    public let flexSum: CGFloat
    public let leadingWeight: Double
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

    init(ffi: SlopDeskWsDivider) {
        self.init(
            splitID: SplitNodeID(ffi: ffi.split),
            childIndex: Int(ffi.child_index),
            axis: ffi.axis == 1 ? .vertical : .horizontal,
            rect: ffi.rect.rect,
            parentSpan: ffi.parent_span,
            flexSum: ffi.flex_sum,
            leadingWeight: ffi.leading_weight,
            trailingWeight: ffi.trailing_weight,
        )
    }

    private var ffi: SlopDeskWsDivider {
        SlopDeskWsDivider(
            split: splitID.ffi,
            child_index: UInt32(clamping: childIndex),
            axis: axis == .vertical ? 1 : 0,
            rect: SlopDeskWsRect(rect),
            parent_span: parentSpan,
            flex_sum: flexSum,
            leading_weight: leadingWeight,
            trailing_weight: trailingWeight,
        )
    }

    /// Whether the seam can still move TOWARD the leading child — shrinking it, growing its
    /// neighbour. Dead once that child sits at the solver's pixel floor, which is exactly where
    /// ``clampedLeadingWeight(_:)`` stops a live drag.
    public var canMoveTowardLeading: Bool { slopdesk_ws_divider_can_move(ffi, true) }

    /// The mirror: movable toward the TRAILING child.
    public var canMoveTowardTrailing: Bool { slopdesk_ws_divider_can_move(ffi, false) }

    /// A live drag's proposed leading weight, clamped so BOTH panes keep that pixel floor.
    public func clampedLeadingWeight(_ proposed: Double) -> Double {
        slopdesk_ws_divider_clamped_weight(ffi, proposed)
    }

    /// One incremental pixel drag along this seam's axis, as the weight delta to offset from:
    /// `Δpixel / parentSpan * flexSum`, the inverse of a flex child's `extent = weight/flexSum·span`.
    /// The seam's own span and flex sum come from the handle, so the seam tracks the cursor 1:1 in a
    /// nested split as well as a top-level one. A handle without geometry answers 0.
    public func weightDelta(pixelIncrement: CGFloat) -> Double {
        slopdesk_ws_divider_weight_delta(ffi, Double(pixelIncrement))
    }

    /// The live drag's ratio readout (`62 · 38`): the pair as whole percentages summing to exactly
    /// 100, or `nil` for a degenerate pair (a `.fixed` side reports weight 0) — the cue is then
    /// absent, never wrong.
    public var splitPercents: (leading: Int, trailing: Int)? {
        var leading: UInt32 = 0
        var trailing: UInt32 = 0
        guard slopdesk_ws_divider_percents(ffi, &leading, &trailing) else { return nil }
        return (Int(leading), Int(trailing))
    }

    /// A **stable** SwiftUI identity for the handle — its STRUCTURAL position in the tree,
    /// INDEPENDENT of the live `rect`/`leadingWeight`. A `ForEach` rendering the dividers MUST key
    /// on this, NOT `\.self`: the synthesized `==` includes `rect`+`leadingWeight`, which change on
    /// EVERY live-drag frame, so a `\.self` id changes every frame → SwiftUI tears down + recreates
    /// the divider view mid-drag and CANCELS the in-flight resize gesture (the drag stalls partway
    /// and fires its release early, so the final reflow never lands). There is at most one seam per
    /// `(split, leading-index)`, so this is unique per layout.
    public struct Key: Hashable, Sendable {
        public let splitID: SplitNodeID
        public let childIndex: Int
        public let axis: SplitAxis
    }

    /// The stable identity key (see ``Key``). Use this for `ForEach`/`id:` — never `\.self`.
    public var key: Key { Key(splitID: splitID, childIndex: childIndex, axis: axis) }
}

extension SplitWeight {
    /// Whether this is a fixed extent in points rather than a proportional share.
    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    /// The magnitude, whichever kind it is — the flag above says how to read it.
    var magnitude: Double {
        switch self {
        case let .flex(share): share
        case let .fixed(points): points
        }
    }

    /// The flat pair the weights codec writes a dragged split's shares as.
    var ffi: SlopDeskWsShare { SlopDeskWsShare(is_fixed: isFixed, value: magnitude) }
}
