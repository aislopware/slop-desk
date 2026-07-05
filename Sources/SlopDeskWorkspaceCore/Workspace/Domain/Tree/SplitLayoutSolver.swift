import CoreGraphics
import Foundation

// MARK: - Split-tree geometry solver (replaces Canvas.solvedLayout / CanvasGeometry partition)

/// Pure flex-weight partition for the tiled ``SplitNode`` tree (docs/42 §Domain model "Solver"). Given a
/// bounding `CGRect` and a tree, it returns every leaf's exact `CGRect` by recursively dividing the bound
/// along each split's axis in proportion to its children's weights — the geometry source of truth fed to
/// BOTH the render and ``FocusResolver`` (so "move focus left" always matches the pane the user sees).
///
/// Free of SwiftUI; `CGRect`/`CGFloat` math only, so it unit-tests headless with no window server. Float
/// math follows the house idiom: separate `*` and `+` (never `addingProduct`/`fma`) and NaN-faithful
/// ordered `Double.maximum`/`Double.minimum` (never a bare `<`/`>` ternary).
public enum SplitLayoutSolver {
    /// The default minimum on-screen size of a leaf — mirrors `Canvas.minItemSize`. A leaf is never
    /// solved smaller than this even when the bound can't hold every sibling (the clamp is a floor: in
    /// that pathological case the rects may exceed the bound rather than collapse a pane to nothing).
    public static let defaultMinLeaf = CGSize(width: 160, height: 120)

    /// Solves `root` inside `rect`, returning each leaf ``PaneID``'s rect. `minLeaf` floors every leaf's
    /// width/height. Pure + total: a finite `rect` yields finite rects for exactly `root.allPaneIDs()`.
    public static func solve(
        _ root: SplitNode,
        in rect: CGRect,
        minLeaf: CGSize = Self.defaultMinLeaf,
    ) -> [PaneID: CGRect] {
        var out: [PaneID: CGRect] = [:]
        place(root, in: rect, minLeaf: minLeaf, into: &out)
        return out
    }

    // MARK: Recursive descent

    private static func place(
        _ node: SplitNode,
        in rect: CGRect,
        minLeaf: CGSize,
        into out: inout [PaneID: CGRect],
    ) {
        switch node {
        case let .leaf(id):
            out[id] = clamp(rect, minLeaf: minLeaf)

        case let .split(_, axis, children):
            guard !children.isEmpty else { return }
            let extents = extents(for: children, total: axisLength(of: rect, axis: axis))
            var cursor = axisOrigin(of: rect, axis: axis)
            for (child, extent) in zip(children, extents) {
                let childRect = subRect(of: rect, axis: axis, origin: cursor, extent: extent)
                place(child.node, in: childRect, minLeaf: minLeaf, into: &out)
                cursor += extent
            }
        }
    }

    // MARK: Weight → extent partition

    /// The point-extent of each child along `axis` within `total` points: ``SplitWeight/fixed(_:)``
    /// children are reserved first, each clamped against a RUNNING remaining-budget (so the fixed *sum*
    /// never exceeds the bound and no two fixed bands overlap), then the flex children divide the points
    /// left over in proportion to their (already-clamped) flex weights. A degenerate all-zero-flex case
    /// falls back to an equal split so no pane vanishes. Pure. (The partition is axis-agnostic — `total`
    /// is already the bound's length along the relevant axis.)
    ///
    /// `internal` (not private) so ``SplitTreeRenderModel`` can reuse the EXACT same un-clamped partition
    /// to place its divider handles on the same seams the solver tiles to (no second, drifting copy).
    static func extents(for children: [WeightedChild], total: CGFloat) -> [CGFloat] {
        // First pass: RESERVE each fixed child its per-child extent with a RUNNING clamp (so the fixed sum
        // is ≤ total and no band overruns the bound), recording that exact extent per index. Pass 2 reuses
        // it verbatim — emitting the same per-child share, NOT the whole bound — so the two passes are
        // consistent by construction and `.fixed` children can never overlap or overflow.
        var fixedTotal: CGFloat = 0
        var flexSum = 0.0
        // `fixedExtents[index]` holds the reserved extent for a `.fixed` child at that position (nil for flex).
        var fixedExtents = [CGFloat?](repeating: nil, count: children.count)
        for (index, child) in children.enumerated() {
            switch child.weight {
            case let .fixed(points):
                // Ordered clamp into [0, remaining] — never let one fixed band overrun the bound. Record
                // this exact reserved extent so pass 2 emits the SAME value (consistent by construction).
                let remaining = Double.maximum(Double(total) - Double(fixedTotal), 0)
                let p = Double.minimum(Double.maximum(points, 0), remaining)
                fixedExtents[index] = CGFloat(p)
                fixedTotal += CGFloat(p)
            case let .flex(w):
                flexSum += Double.maximum(w, 0)
            }
        }

        // Points left for the flex children after the fixed bands are reserved.
        let flexBudget = Double.maximum(Double(total) - Double(fixedTotal), 0)
        // The number of flex children — used for the all-zero-flex equal-split fallback.
        let flexCount = children.reduce(0) { acc, child in
            if case .flex = child.weight { return acc + 1 }
            return acc
        }

        var extentsOut: [CGFloat] = []
        extentsOut.reserveCapacity(children.count)
        for (index, child) in children.enumerated() {
            switch child.weight {
            case .fixed:
                // Reuse the per-child reserved extent from pass 1 (NOT the whole bound) so fixed bands tile
                // without overlap. `fixedExtents[index]` is always set for a `.fixed` child (set above).
                extentsOut.append(fixedExtents[index] ?? 0)
            case let .flex(w):
                let share: Double
                if flexSum > 0 {
                    // Proportional share — separate `*` then `/` (never fma), of the flex budget.
                    let weight = Double.maximum(w, 0)
                    share = flexBudget * weight / flexSum
                } else if flexCount > 0 {
                    // All flex weights collapsed to 0 → equal split of the budget.
                    share = flexBudget / Double(flexCount)
                } else {
                    share = 0
                }
                extentsOut.append(CGFloat(share))
            }
        }
        return extentsOut
    }

    // MARK: Axis-aware rect helpers

    /// The length of `rect` along `axis` (`horizontal` → width, `vertical` → height).
    private static func axisLength(of rect: CGRect, axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.width
        case .vertical: rect.height
        }
    }

    /// The origin of `rect` along `axis` (`horizontal` → minX, `vertical` → minY).
    private static func axisOrigin(of rect: CGRect, axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.minX
        case .vertical: rect.minY
        }
    }

    /// A child rect at `origin` with `extent` along `axis`; the cross-axis spans the full parent.
    private static func subRect(of rect: CGRect, axis: SplitAxis, origin: CGFloat, extent: CGFloat) -> CGRect {
        switch axis {
        case .horizontal:
            CGRect(x: origin, y: rect.minY, width: extent, height: rect.height)
        case .vertical:
            CGRect(x: rect.minX, y: origin, width: rect.width, height: extent)
        }
    }

    /// `rect` with its width/height floored to `minLeaf` (the per-leaf minimum-size clamp). A non-finite
    /// extent collapses to the corresponding `minLeaf` component so a NaN can never reach the renderer.
    private static func clamp(_ rect: CGRect, minLeaf: CGSize) -> CGRect {
        let w = rect.width.isFinite ? Double.maximum(Double(rect.width), Double(minLeaf.width)) : Double(minLeaf.width)
        let h = rect.height.isFinite ? Double
            .maximum(Double(rect.height), Double(minLeaf.height)) : Double(minLeaf.height)
        let x = rect.minX.isFinite ? rect.minX : 0
        let y = rect.minY.isFinite ? rect.minY : 0
        return CGRect(x: x, y: y, width: CGFloat(w), height: CGFloat(h))
    }
}
