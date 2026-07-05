import Foundation

// MARK: - Split axis

/// The direction a ``SplitNode/split(id:axis:children:)`` lays its children out (docs/42 §Domain model).
///
/// `String`-raw so the persisted JSON discriminator is human-readable and versionable (mirrors
/// ``PaneKind``). `.horizontal` = side-by-side **columns** (children partition the parent's *width*);
/// `.vertical` = stacked **rows** (children partition the *height*).
public enum SplitAxis: String, Codable, Sendable, Equatable {
    /// Children sit side-by-side as columns — the split partitions the bound's width.
    case horizontal
    /// Children stack as rows — the split partitions the bound's height.
    case vertical
}

// MARK: - Drop edge (drag-to-re-split / dock)

/// A side a pane can be dropped against in the drag-to-re-split / dock-to-edge gesture — of a hovered
/// target leaf (``WorkspaceTreeOps/moveLeaf(_:beside:axis:before:in:)``) or of the whole container
/// (``WorkspaceTreeOps/moveLeafToRootEdge(_:edge:in:)``). It maps a screen edge to the split ``SplitAxis``
/// and the insertion side, so the UI hit-test and the pure tree ops read ONE source of truth and the
/// edge→axis mapping can never drift (the easy place to invert it). `.left`/`.right` form COLUMNS (a
/// `.horizontal` split partitions width); `.top`/`.bottom` form ROWS (a `.vertical` split partitions
/// height) — so dropping a side-by-side pane on another's TOP edge stacks them (the user's "dọc → ngang").
public enum PaneDropEdge: String, Sendable, Equatable, CaseIterable {
    case left
    case right
    case top
    case bottom

    /// The split axis a drop on this edge forms: `.left`/`.right` → `.horizontal` (columns), `.top`/
    /// `.bottom` → `.vertical` (rows).
    public var axis: SplitAxis {
        switch self {
        case .left,
             .right:
            .horizontal
        case .top,
             .bottom:
            .vertical
        }
    }

    /// Whether the dropped pane is inserted BEFORE the target/root along the axis (`.left`/`.top`) or
    /// after it (`.right`/`.bottom`).
    public var insertsBefore: Bool {
        switch self {
        case .left,
             .top:
            true
        case .right,
             .bottom:
            false
        }
    }
}

// MARK: - Child weight

/// A child's share of its parent split along the split axis (docs/42 §Domain model).
///
/// - ``flex(_:)``: a proportional share, normalized against its siblings at layout time (the default is
///   `.flex(1)` = an equal share). Always clamped to ``minWeight`` on decode so a zero / negative /
///   non-finite value can never starve a pane to nothing.
/// - ``fixed(_:)``: a fixed number of points along the parent axis, subtracted from the bound *before*
///   the flex children divide the remainder. Schema-reserved for fixed sidebars; the W1 solver supports
///   it but the MVP tree only mints `.flex`.
public enum SplitWeight: Codable, Sendable, Equatable {
    case flex(Double)
    case fixed(Double)

    /// The floor every `.flex` share is clamped to — a pane always keeps a sliver of the axis even when
    /// a hostile / corrupt file set its weight to 0, a negative, or NaN.
    public static let minWeight = 0.05

    /// This weight with any non-finite / sub-floor magnitude repaired:
    /// `.flex` clamps to ``minWeight``; `.fixed` clamps a non-finite / negative extent to 0 (a fixed
    /// child can legitimately be 0 points = absent, but never NaN). Pure + total.
    func repaired() -> Self {
        switch self {
        case let .flex(w):
            // NaN/inf → minWeight; ordered max (NaN-faithful) floors at minWeight.
            let safe = w.isFinite ? Double.maximum(w, Self.minWeight) : Self.minWeight
            return .flex(safe)
        case let .fixed(p):
            let safe = p.isFinite ? Double.maximum(p, 0) : 0
            return .fixed(safe)
        }
    }
}

// MARK: - Weighted child

/// One child slot of a ``SplitNode/split(id:axis:children:)`` — a subtree plus its share of the parent
/// axis. A pure value (docs/42 §Domain model).
public struct WeightedChild: Codable, Sendable, Equatable {
    public var weight: SplitWeight
    public var node: SplitNode
    public init(weight: SplitWeight, node: SplitNode) {
        self.weight = weight
        self.node = node
    }
}

// MARK: - The recursive split tree

/// The recursive, **n-ary** tiled split tree of a ``Tab`` (docs/42 §Decisions.1, Zellij model). A pure
/// `Codable`/`Equatable`/`Sendable` value with **no SwiftUI / transport import** — it stores only
/// ``PaneID``s (identity/geometry), never a live object; a pane's ``PaneSpec`` lives in the owning
/// session's side table.
///
/// - ``leaf(_:)`` is a single pane.
/// - ``split(id:axis:children:)`` partitions its bound along `axis` among `children` by their weights.
///   N-ary (not binary) so closing the Nth sibling redistributes flex equally among the survivors with
///   no redundant intermediary nodes.
///
/// **Invariants** (enforced by the decoder in `SplitNode+Codable.swift`, validate-then-repair): a
/// `.split` always has ≥ 2 children (a 1-child split collapses into its child, a 0-child split is
/// dropped); no `.split` child shares its parent's axis (same-axis children are flattened — the Zellij
/// merge); every ``PaneID`` is unique (duplicates re-minted); every weight is finite and ≥
/// ``SplitWeight/minWeight``; depth ≤ ``maxDepth``. Construct directly only with these held, or pass
/// through the decode/`normalized()` repair.
public indirect enum SplitNode: Sendable, Equatable {
    case leaf(PaneID)
    case split(id: SplitNodeID, axis: SplitAxis, children: [WeightedChild])

    /// The maximum nesting depth the decoder will keep — a corrupt / hostile file nested past this is
    /// capped (the over-deep tail collapses to its first leaf) so decode is bounded and the render /
    /// solver recursion can never stack-overflow. Far above any real layout (a human nests a handful).
    public static let maxDepth = 12
}

// MARK: - Pure queries (DFS helpers the ops + solver + store read)

public extension SplitNode {
    /// Every ``PaneID`` in the tree, in **pre-order DFS** (a `.leaf` yields itself; a `.split` yields its
    /// children left-to-right). Drives the store's reconcile diff and the focus cycle, so the order is
    /// deterministic. (reconcile compares it as a `Set`; the order matters for cycling + the carousel.)
    func allPaneIDs() -> [PaneID] {
        switch self {
        case let .leaf(id):
            return [id]
        case let .split(_, _, children):
            var ids: [PaneID] = []
            for child in children {
                ids.append(contentsOf: child.node.allPaneIDs())
            }
            return ids
        }
    }

    /// The number of leaves (panes) in the tree — a `.leaf` is 1, a `.split` is the sum of its children.
    var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case let .split(_, _, children):
            var count = 0
            for child in children { count += child.node.leafCount }
            return count
        }
    }

    /// The nesting depth: a `.leaf` is 1; a `.split` is 1 + the deepest child. Used to enforce
    /// ``maxDepth`` (decode cap) and in tests.
    var depth: Int {
        switch self {
        case .leaf:
            return 1
        case let .split(_, _, children):
            var deepest = 0
            for child in children {
                // Ordered max (NaN-irrelevant for Int, but keeps the house idiom of no bare `>` ternary).
                deepest = max(deepest, child.node.depth)
            }
            return 1 + deepest
        }
    }

    /// Whether `id` names a leaf anywhere in the tree.
    func contains(_ id: PaneID) -> Bool {
        switch self {
        case let .leaf(leafID):
            return leafID == id
        case let .split(_, _, children):
            for child in children where child.node.contains(id) { return true }
            return false
        }
    }

    /// Structural equality that IGNORES ``SplitNodeID``s: two trees are structurally equal iff they have the
    /// same shape (axis + ordered children count), the same leaf ids in the same positions, and the same
    /// weights. The synthesized `==` includes the split id, so a rebuild that reproduces the same
    /// arrangement under a freshly-minted id looks "changed" to `!=`; a relocate uses this to detect a true
    /// no-op drop (drop a pane where it already sits) and skip the reconcile/save churn. Pure.
    func isStructurallyEqual(to other: SplitNode) -> Bool {
        switch (self, other) {
        case let (.leaf(a), .leaf(b)):
            return a == b
        case let (.split(_, axisA, childrenA), .split(_, axisB, childrenB)):
            guard axisA == axisB, childrenA.count == childrenB.count else { return false }
            for (ca, cb) in zip(childrenA, childrenB) {
                guard ca.weight == cb.weight, ca.node.isStructurallyEqual(to: cb.node) else { return false }
            }
            return true
        default:
            return false
        }
    }
}
