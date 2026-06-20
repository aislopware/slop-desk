import Foundation

// MARK: - Pure split-tree operations (docs/42 §"Pure ops" — SplitNode+Ops.swift)

/// Pure transformations on the recursive ``SplitNode`` tree: each returns a NEW tree, never mutates in
/// place, and preserves the tree invariants (≥ 2 children per split, no redundant same-axis nesting,
/// finite ≥ ``SplitWeight/minWeight`` flex weights). No I/O, no GUI.
///
/// Float math follows the house idiom — separate `*`/`+`/`/` (never `addingProduct`/`fma`) and
/// NaN-faithful ordered `Double.maximum`/`Double.minimum` (never a bare `<`/`>` ternary).
public extension SplitNode {
    // MARK: Split a target leaf

    /// Splits leaf `target` along `axis`, inserting `newLeaf` as a sibling. Returns the new tree, or
    /// `nil` if `target` is not a leaf in this tree (caller treats `nil` as a no-op).
    ///
    /// - If the *parent* split of `target` already has `axis`, `newLeaf` is inserted as a sibling
    ///   immediately after `target` (n-ary insert — no redundant intermediary; matches Zellij).
    /// - Otherwise (the root leaf, or a parent with the other axis) the `target` leaf is replaced by a
    ///   fresh 2-child `.split(axis:)` of `[target, newLeaf]` with equal flex weights.
    func splitting(_ target: PaneID, axis: SplitAxis, inserting newLeaf: PaneID) -> SplitNode? {
        guard contains(target) else { return nil }
        return splitImpl(target, axis: axis, newLeaf: newLeaf)
    }

    /// Recursive worker. The same-axis-as-parent sibling insert is detected at each `.split` node (it owns
    /// its children), so the worker doesn't thread the parent axis down.
    private func splitImpl(_ target: PaneID, axis: SplitAxis, newLeaf: PaneID) -> SplitNode {
        switch self {
        case let .leaf(id):
            guard id == target else { return self }
            // Replace the leaf with a 2-child split along `axis`. (The same-axis-as-parent insert is
            // handled by the parent `.split` case below before it ever recurses into the leaf.)
            return .split(
                id: SplitNodeID(),
                axis: axis,
                children: [
                    WeightedChild(weight: .flex(1), node: .leaf(target)),
                    WeightedChild(weight: .flex(1), node: .leaf(newLeaf)),
                ],
            )

        case let .split(id, splitAxis, children):
            // Does a DIRECT child leaf equal the target AND does this split share the requested axis?
            // Then insert the new leaf as a sibling right after the target (the n-ary insert).
            if splitAxis == axis,
               let idx = children.firstIndex(where: { if case .leaf(target) = $0.node { return true }
                   return false
               })
            {
                var newChildren = children
                // New sibling gets the equal-share weight of the existing children's average flex so the
                // insert doesn't visibly resize its neighbours (re-normalized at layout anyway).
                let inserted = WeightedChild(weight: .flex(insertWeight(of: children)), node: .leaf(newLeaf))
                newChildren.insert(inserted, at: idx + 1)
                return .split(id: id, axis: splitAxis, children: newChildren)
            }
            // Otherwise recurse into the child that contains the target.
            let newChildren = children.map { child -> WeightedChild in
                guard child.node.contains(target) else { return child }
                return WeightedChild(
                    weight: child.weight,
                    node: child.node.splitImpl(target, axis: axis, newLeaf: newLeaf),
                )
            }
            return .split(id: id, axis: splitAxis, children: newChildren)
        }
    }

    /// The flex weight a newly inserted sibling should take: the mean of the existing children's flex
    /// weights (so it lands at an equal share). Falls back to `1` when there are no flex children. Pure.
    private func insertWeight(of children: [WeightedChild]) -> Double {
        var sum = 0.0
        var count = 0
        for child in children {
            if case let .flex(w) = child.weight {
                sum += w
                count += 1
            }
        }
        guard count > 0 else { return 1 }
        return sum / Double(count)
    }

    // MARK: Remove a leaf

    /// Removes leaf `target` from the tree, collapsing the now-single-child parent and re-balancing the
    /// surviving siblings' flex weights to an equal share (sum-preserving over survivors). Returns the new
    /// tree, or `nil` if removing `target` would empty the tree (a lone leaf == target → the caller
    /// handles the empty-tab cascade). A no-op tree (target absent) returns `self`.
    func removing(_ target: PaneID) -> SplitNode? {
        guard contains(target) else { return self }
        return removeImpl(target)
    }

    private func removeImpl(_ target: PaneID) -> SplitNode? {
        switch self {
        case let .leaf(id):
            // Removing the lone leaf empties this subtree → signal nil to the parent (or the whole tree).
            return id == target ? nil : self

        case let .split(id, axis, children):
            var survivors: [WeightedChild] = []
            for child in children {
                if case let .leaf(leafID) = child.node, leafID == target {
                    continue // drop the target leaf
                }
                if let pruned = child.node.removeImpl(target) {
                    survivors.append(WeightedChild(weight: child.weight, node: pruned))
                }
                // A child that pruned to nil (e.g. a nested split whose only leaf was the target) is
                // dropped too.
            }
            switch survivors.count {
            case 0:
                return nil // the whole split emptied
            case 1:
                // Single-child split collapses into its child (no orphan intermediary).
                return survivors[0].node
            default:
                // Re-balance the survivors' FLEX weights to an equal share (sum-preserving): the total
                // flex weight is conserved and split evenly so the freed space redistributes equally
                // among the N survivors — the n-ary close-rebalance the plan specifies.
                return .split(id: id, axis: axis, children: rebalanced(survivors))
            }
        }
    }

    /// Re-balances a survivor list so every `.flex` child carries an equal share of the original total
    /// flex weight (sum-preserving). `.fixed` children keep their points (only flex redistributes). Pure;
    /// separate `/` (never fma).
    private func rebalanced(_ children: [WeightedChild]) -> [WeightedChild] {
        var flexSum = 0.0
        var flexCount = 0
        for child in children {
            if case let .flex(w) = child.weight {
                flexSum += w
                flexCount += 1
            }
        }
        guard flexCount > 0 else { return children }
        let equal = flexSum / Double(flexCount)
        // Floor the equal share so a degenerate near-zero total can't drop below minWeight.
        let share = Double.maximum(equal, SplitWeight.minWeight)
        return children.map { child in
            if case .flex = child.weight {
                return WeightedChild(weight: .flex(share), node: child.node)
            }
            return child
        }
    }

    // MARK: Resize a divider

    /// Shifts flex weight by `delta` between the children at `leadingIndex` and `leadingIndex + 1` of the
    /// split identified by `splitID` (the divider sits between those two adjacent siblings). The two
    /// weights' SUM is preserved (the leading grows by what the trailing shrinks), and each is clamped at
    /// ``SplitWeight/minWeight`` so neither pane collapses. Returns the new tree (no-op if `splitID` or
    /// the indices are absent, or either child is `.fixed`).
    func resizingDivider(splitID: SplitNodeID, leadingIndex: Int, delta: Double) -> SplitNode {
        switch self {
        case .leaf:
            return self

        case let .split(id, axis, children):
            if id == splitID {
                return .split(
                    id: id,
                    axis: axis,
                    children: shiftWeight(children, leadingIndex: leadingIndex, delta: delta),
                )
            }
            let newChildren = children.map { child in
                WeightedChild(
                    weight: child.weight,
                    node: child.node.resizingDivider(splitID: splitID, leadingIndex: leadingIndex, delta: delta),
                )
            }
            return .split(id: id, axis: axis, children: newChildren)
        }
    }

    /// Sum-preserving, clamped weight shift between two adjacent flex children. Pure.
    private func shiftWeight(_ children: [WeightedChild], leadingIndex: Int, delta: Double) -> [WeightedChild] {
        let trailingIndex = leadingIndex + 1
        guard children.indices.contains(leadingIndex), children.indices.contains(trailingIndex),
              case let .flex(lead) = children[leadingIndex].weight,
              case let .flex(trail) = children[trailingIndex].weight
        else { return children }

        let pairSum = lead + trail
        // Proposed leading weight, clamped into [minWeight, pairSum - minWeight] so BOTH stay ≥ floor and
        // the sum is exactly preserved. Ordered min/max (NaN-faithful).
        let upper = Double.maximum(pairSum - SplitWeight.minWeight, SplitWeight.minWeight)
        let proposed = lead + delta
        let newLead = Double.minimum(Double.maximum(proposed, SplitWeight.minWeight), upper)
        let newTrail = pairSum - newLead

        var out = children
        out[leadingIndex] = WeightedChild(weight: .flex(newLead), node: children[leadingIndex].node)
        out[trailingIndex] = WeightedChild(weight: .flex(newTrail), node: children[trailingIndex].node)
        return out
    }

    // MARK: Swap two leaves

    /// Returns a tree with leaves `a` and `b` exchanged in position (weights stay with the slot, the leaf
    /// ids move). No-op if either is absent. Pure.
    func swapping(_ a: PaneID, _ b: PaneID) -> SplitNode {
        guard a != b, contains(a), contains(b) else { return self }
        return mapLeaves { id in
            if id == a { return b }
            if id == b { return a }
            return id
        }
    }

    /// Returns a tree with every leaf id passed through `transform` (structure + weights unchanged). Pure.
    func mapLeaves(_ transform: (PaneID) -> PaneID) -> SplitNode {
        switch self {
        case let .leaf(id):
            .leaf(transform(id))
        case let .split(id, axis, children):
            .split(id: id, axis: axis, children: children.map { child in
                WeightedChild(weight: child.weight, node: child.node.mapLeaves(transform))
            })
        }
    }

    // MARK: Enclosing split on an axis (the keyboard-resize query)

    /// The nearest ANCESTOR `.split` on `axis` that contains leaf `pane`, as `(splitID, childIndex,
    /// childCount)` where `childIndex` is the position of the DIRECT child subtree (of that split) that
    /// holds `pane` and `childCount` is that split's child count. `nil` if no ancestor split on `axis`
    /// contains the pane (e.g. a sole leaf, or the pane only sits under the other axis). Pure.
    ///
    /// "Nearest" = the DEEPEST matching ancestor: a keyboard width-resize should nudge the divider closest
    /// to the active pane, so we descend toward the leaf and return the last (deepest) split on `axis` whose
    /// direct-child subtree still contains it.
    func enclosingSplit(of pane: PaneID, axis: SplitAxis) -> (splitID: SplitNodeID, childIndex: Int, childCount: Int)? {
        guard contains(pane) else { return nil }
        var best: (splitID: SplitNodeID, childIndex: Int, childCount: Int)?
        enclosingSplitImpl(pane, axis: axis, into: &best)
        return best
    }

    /// Pre-order descent that records the DEEPEST matching split (overwrites a shallower hit) — so the
    /// returned split is the one nearest the leaf. Pure.
    private func enclosingSplitImpl(
        _ pane: PaneID,
        axis: SplitAxis,
        into best: inout (splitID: SplitNodeID, childIndex: Int, childCount: Int)?,
    ) {
        guard case let .split(id, splitAxis, children) = self else { return }
        // The direct-child subtree that holds the pane (there is exactly one — pane ids are unique).
        guard let idx = children.firstIndex(where: { $0.node.contains(pane) }) else { return }
        if splitAxis == axis {
            // A match on this axis — record it, then keep descending so a DEEPER split on the same axis wins.
            best = (id, idx, children.count)
        }
        children[idx].node.enclosingSplitImpl(pane, axis: axis, into: &best)
    }

    // MARK: Rebalance (tmux even-layout)

    /// This subtree with every `.split`'s `.flex` children reset to an EQUAL `.flex(1)` share (recursively),
    /// while `.fixed` children keep their points. The tree SHAPE and the leaf set/order are unchanged — only
    /// the flex weights are equalized (the tmux "select-layout even-*" idiom). Pure.
    func rebalanced() -> SplitNode {
        switch self {
        case .leaf:
            return self
        case let .split(id, axis, children):
            let balancedChildren = children.map { child -> WeightedChild in
                let newWeight: SplitWeight =
                    switch child.weight {
                    case .flex: .flex(1) // equal share — re-normalized proportionally at layout
                    case .fixed: child.weight // fixed bands keep their points
                    }
                return WeightedChild(weight: newWeight, node: child.node.rebalanced())
            }
            return .split(id: id, axis: axis, children: balancedChildren)
        }
    }

    // MARK: Locate

    /// The first leaf of the tree in pre-order DFS (the sensible default focus / the "first survivor"). A
    /// tree always has ≥ 1 leaf, so this is never `nil` for a real tree.
    var firstLeafID: PaneID? {
        allPaneIDs().first
    }
}
