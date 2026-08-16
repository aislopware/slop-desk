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

    /// The point-extent of each child along the split axis within `total` points.
    ///
    /// `public` (not private) so ``SplitTreeRenderModel`` — which lives one module up in
    /// `SlopDeskWorkspaceCore` — reuses the EXACT partition the solver tiles to, and its divider
    /// handles land on the seams rather than a pixel off them.
    public static func extents(for children: [WeightedChild], total: CGFloat) -> [CGFloat] {
        var shares = children.map(\.weight.ffi)
        return shares.withUnsafeMutableBufferPointer { buffer -> [CGFloat] in
            var out = [Double](repeating: 0, count: buffer.count)
            let needed = out.withUnsafeMutableBufferPointer { answer in
                slopdesk_ws_extents(buffer.baseAddress, buffer.count, total, answer.baseAddress, answer.count)
            }
            // One extent per child, always — a mismatch would mean the two sides disagree about how
            // many children there are, and silently returning a short array would misplace a divider.
            guard needed == out.count else { return [] }
            return out.map { CGFloat($0) }
        }
    }
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

    var ffi: SlopDeskWsShare { SlopDeskWsShare(is_fixed: isFixed, value: magnitude) }
}
