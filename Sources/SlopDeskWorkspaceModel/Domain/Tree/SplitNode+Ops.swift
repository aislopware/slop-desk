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

    /// Splits leaf `target` along `axis`, inserting `newLeaf` as a sibling. `before == true` inserts the
    /// new leaf on the LEADING side of `target` (left of a `.horizontal` split / above a `.vertical` split)
    /// rather than the natural trailing side — the split-left/up chords feed `before: true`, every other
    /// split keeps the default `before: false` (trailing). Returns the new tree, or `nil` if `target` is
    /// not a leaf in this tree (caller treats `nil` as a no-op).
    ///
    /// - If the *parent* split of `target` already has `axis`, `newLeaf` is inserted as a sibling
    ///   immediately before/after `target` per `before` (n-ary insert — no redundant intermediary; matches
    ///   Zellij).
    /// - Otherwise (the root leaf, or a parent with the other axis) the `target` leaf is replaced by a
    ///   fresh 2-child `.split(axis:)` ordered `[newLeaf, target]` when `before` else `[target, newLeaf]`,
    ///   with equal flex weights.
    func splitting(_ target: PaneID, axis: SplitAxis, inserting newLeaf: PaneID, before: Bool = false) -> SplitNode? {
        guard contains(target) else { return nil }
        return splitImpl(target, axis: axis, newLeaf: newLeaf, before: before)
    }

    /// Recursive worker. The same-axis-as-parent sibling insert is detected at each `.split` node (it owns
    /// its children), so the worker doesn't thread the parent axis down.
    private func splitImpl(_ target: PaneID, axis: SplitAxis, newLeaf: PaneID, before: Bool) -> SplitNode {
        switch self {
        case let .leaf(id):
            guard id == target else { return self }
            // Replace the leaf with a 2-child split along `axis`, ordering the new leaf per `before`. (The
            // same-axis-as-parent insert is handled by the parent `.split` case below before it ever
            // recurses into the leaf.)
            let targetChild = WeightedChild(weight: .flex(1), node: .leaf(target))
            let newChild = WeightedChild(weight: .flex(1), node: .leaf(newLeaf))
            return .split(
                id: SplitNodeID(),
                axis: axis,
                children: before ? [newChild, targetChild] : [targetChild, newChild],
            )

        case let .split(id, splitAxis, children):
            // Does a DIRECT child leaf equal the target AND does this split share the requested axis?
            // Then insert the new leaf as a sibling before/after the target per `before` (the n-ary insert).
            if splitAxis == axis,
               let idx = children.firstIndex(where: { if case .leaf(target) = $0.node { return true }
                   return false
               })
            {
                var newChildren = children
                // New sibling gets the equal-share weight of the existing children's average flex so the
                // insert doesn't visibly resize its neighbours (re-normalized at layout anyway).
                let inserted = WeightedChild(weight: .flex(insertWeight(of: children)), node: .leaf(newLeaf))
                newChildren.insert(inserted, at: before ? idx : idx + 1)
                return .split(id: id, axis: splitAxis, children: newChildren)
            }
            // Otherwise recurse into the child that contains the target.
            let newChildren = children.map { child -> WeightedChild in
                guard child.node.contains(target) else { return child }
                return WeightedChild(
                    weight: child.weight,
                    node: child.node.splitImpl(target, axis: axis, newLeaf: newLeaf, before: before),
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

    // MARK: Insert an EXISTING leaf beside a target (drag-to-re-split)

    /// Inserts the EXISTING leaf id `leaf` as a sibling of `target` along `axis`, on the BEFORE side when
    /// `before == true` (else after). The drop-on-an-edge counterpart to ``splitting(_:axis:inserting:)``:
    /// that one mints a brand-new pane and only inserts AFTER; this one carries an id the caller already
    /// pruned from elsewhere and can insert on EITHER side, so a pane dragged onto a target's left/top edge
    /// lands before it and onto the right/bottom edge after it. Returns the new tree, or `nil` if `target`
    /// is absent (caller treats `nil` as a no-op).
    ///
    /// Same n-ary rule as `splitting`: if `target`'s parent split already has `axis`, `leaf` is inserted as
    /// a plain sibling at the before/after slot (no redundant same-axis nesting — the Zellij merge); else
    /// the `target` leaf is replaced by a fresh 2-child `.split(axis:)` ordered per `before`. The caller
    /// guarantees `leaf` is not already in this tree (it pruned `leaf` first), so the leaf set grows by one.
    func inserting(_ leaf: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) -> SplitNode? {
        guard contains(target) else { return nil }
        return insertBesideImpl(leaf, beside: target, axis: axis, before: before)
    }

    private func insertBesideImpl(_ leaf: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) -> SplitNode {
        switch self {
        case let .leaf(id):
            guard id == target else { return self }
            // Replace the bare leaf with a 2-child split along `axis`, ordering the new leaf per `before`.
            let targetChild = WeightedChild(weight: .flex(1), node: .leaf(target))
            let newChild = WeightedChild(weight: .flex(1), node: .leaf(leaf))
            return .split(
                id: SplitNodeID(),
                axis: axis,
                children: before ? [newChild, targetChild] : [targetChild, newChild],
            )

        case let .split(id, splitAxis, children):
            // A DIRECT child leaf equals target AND this split shares `axis` → plain sibling insert (n-ary).
            if splitAxis == axis,
               let idx = children.firstIndex(where: { if case .leaf(target) = $0.node { return true }
                   return false
               })
            {
                var newChildren = children
                let inserted = WeightedChild(weight: .flex(insertWeight(of: children)), node: .leaf(leaf))
                newChildren.insert(inserted, at: before ? idx : idx + 1)
                return .split(id: id, axis: splitAxis, children: newChildren)
            }
            // Otherwise recurse into the child subtree that contains target.
            let newChildren = children.map { child -> WeightedChild in
                guard child.node.contains(target) else { return child }
                return WeightedChild(
                    weight: child.weight,
                    node: child.node.insertBesideImpl(leaf, beside: target, axis: axis, before: before),
                )
            }
            return .split(id: id, axis: splitAxis, children: newChildren)
        }
    }

    // MARK: Insert an EXISTING leaf at the ROOT edge (drag-to-dock)

    /// Inserts the EXISTING leaf id `leaf` as the OUTERMOST child of the tree along `axis`, on the BEFORE
    /// side when `before` (else after) — the drag-to-dock counterpart of
    /// ``inserting(_:beside:axis:before:)`` for a drop on the CONTAINER's outer edge, where there is no
    /// target leaf to sit beside. The new pane spans the full cross-axis extent of the whole tab.
    ///
    /// - If the ROOT is a `.split` already on `axis`: `leaf` is prepended/appended as the outermost flat
    ///   sibling (full span falls out of the flat split — the Zellij merge, no nesting).
    /// - Otherwise (the root is a bare leaf, or a `.split` on the OTHER axis): the whole root is WRAPPED in a
    ///   fresh 2-child `.split(axis:)` of `[leaf, root]` (before) or `[root, leaf]` (after).
    ///
    /// The caller guarantees `leaf` is not already in the tree (it pruned `leaf` first), so the leaf set
    /// grows by one. Pure; preserves the ≥2-children / no-same-axis-nesting / minWeight guarantees.
    func insertingAtRoot(_ leaf: PaneID, axis: SplitAxis, before: Bool) -> SplitNode {
        if case let .split(id, splitAxis, children) = self, splitAxis == axis {
            var newChildren = children
            let inserted = WeightedChild(weight: .flex(insertWeight(of: children)), node: .leaf(leaf))
            newChildren.insert(inserted, at: before ? 0 : newChildren.count)
            return .split(id: id, axis: splitAxis, children: newChildren)
        }
        // Wrap the whole root (a bare leaf, or a split on the OTHER axis) in a fresh 2-child split.
        let rootChild = WeightedChild(weight: .flex(1), node: self)
        let newChild = WeightedChild(weight: .flex(1), node: .leaf(leaf))
        return .split(
            id: SplitNodeID(),
            axis: axis,
            children: before ? [newChild, rootChild] : [rootChild, newChild],
        )
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
            // Splice any surviving child that is itself a `.split` on THIS axis up into this level (the
            // Zellij same-axis merge). A collapse can promote a single-child parent's survivor that happens
            // to share the grandparent's axis (e.g. `V[ H[V[a,b], c], d ]` losing `c` collapses the `H` and
            // floats `V[a,b]` straight under the `V` root → a redundant `V[V[a,b], d]`). Without this merge
            // the live tree carries a same-axis nest the decoder would later flatten — skewing the
            // rebalance + over-counting depth (the live-op path never re-runs `normalized()`). One pass
            // suffices: a valid child split never nests its own axis, so a spliced grandchild can't share
            // `axis`. Mirrors `SplitNode.normalized()`'s flatten.
            let merged = mergingSameAxis(survivors, axis: axis)
            switch merged.count {
            case 0:
                return nil // the whole split emptied
            case 1:
                // Single-child split collapses into its child (no orphan intermediary).
                return merged[0].node
            default:
                // Re-balance the survivors' FLEX weights to an equal share (sum-preserving): the total
                // flex weight is conserved and split evenly so the freed space redistributes equally
                // among the N survivors — the n-ary close-rebalance the plan specifies.
                return .split(id: id, axis: axis, children: rebalanced(merged))
            }
        }
    }

    /// Splices any child that is itself a `.split` on `axis` up into this level (the Zellij same-axis
    /// merge the decoder applies in `normalized()`). The spliced grandchildren keep their nodes (the caller
    /// re-balances the flex weights). Pure; one pass is enough because a valid child split never nests its
    /// own axis.
    private func mergingSameAxis(_ children: [WeightedChild], axis: SplitAxis) -> [WeightedChild] {
        var out: [WeightedChild] = []
        for child in children {
            if case let .split(_, childAxis, grandchildren) = child.node, childAxis == axis {
                out.append(contentsOf: grandchildren)
            } else {
                out.append(child)
            }
        }
        return out
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

    /// Evens ONLY the seam between the children at `leadingIndex` and `leadingIndex + 1` of the split
    /// identified by `splitID` (the divider double-click): both flex weights become their pair MEAN
    /// (sum-preserving), so every OTHER divider of this split — and every other split in the tree — keeps
    /// its dragged ratio (unlike ``rebalanced()``, the whole-tree even reset). Returns the new tree (no-op
    /// if `splitID` or the indices are absent, or either child is `.fixed`).
    func eveningDivider(splitID: SplitNodeID, leadingIndex: Int) -> SplitNode {
        switch self {
        case .leaf:
            return self

        case let .split(id, axis, children):
            if id == splitID {
                return .split(id: id, axis: axis, children: evenPair(children, leadingIndex: leadingIndex))
            }
            let newChildren = children.map { child in
                WeightedChild(
                    weight: child.weight,
                    node: child.node.eveningDivider(splitID: splitID, leadingIndex: leadingIndex),
                )
            }
            return .split(id: id, axis: axis, children: newChildren)
        }
    }

    /// Sets two adjacent flex children to the mean of their pair sum (a sum-preserving 50/50 for the one
    /// seam), floored at ``SplitWeight/minWeight`` like ``rebalanced()``'s degenerate-total guard. Pure.
    private func evenPair(_ children: [WeightedChild], leadingIndex: Int) -> [WeightedChild] {
        let trailingIndex = leadingIndex + 1
        guard children.indices.contains(leadingIndex), children.indices.contains(trailingIndex),
              case let .flex(lead) = children[leadingIndex].weight,
              case let .flex(trail) = children[trailingIndex].weight
        else { return children }

        let share = Double.maximum((lead + trail) / 2, SplitWeight.minWeight)
        var out = children
        out[leadingIndex] = WeightedChild(weight: .flex(share), node: children[leadingIndex].node)
        out[trailingIndex] = WeightedChild(weight: .flex(share), node: children[trailingIndex].node)
        return out
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

    /// Sets the ABSOLUTE leading-child weight of split `splitID`'s divider at `leadingIndex` (the trailing
    /// sibling takes the remainder, so the pair SUM is preserved and both stay ≥ ``SplitWeight/minWeight``).
    /// The cursor-matched form of ``resizingDivider(splitID:leadingIndex:delta:)`` for a LIVE drag: the caller
    /// passes `startWeight + Δpx·flexSum/span` from a stable cursor translation, so the seam holds at the clamp
    /// during an over-drag and resumes only when the cursor returns — no drift an incremental delta would
    /// accumulate. No-op if `splitID` / the indices are absent, or either child is `.fixed`.
    func settingDividerWeight(splitID: SplitNodeID, leadingIndex: Int, leadingWeight: Double) -> SplitNode {
        switch self {
        case .leaf:
            return self

        case let .split(id, axis, children):
            if id == splitID {
                return .split(
                    id: id,
                    axis: axis,
                    children: setWeight(children, leadingIndex: leadingIndex, leadingWeight: leadingWeight),
                )
            }
            let newChildren = children.map { child in
                WeightedChild(
                    weight: child.weight,
                    node: child.node.settingDividerWeight(
                        splitID: splitID, leadingIndex: leadingIndex, leadingWeight: leadingWeight,
                    ),
                )
            }
            return .split(id: id, axis: axis, children: newChildren)
        }
    }

    /// Sum-preserving, clamped ABSOLUTE weight set between two adjacent flex children. Pure.
    private func setWeight(
        _ children: [WeightedChild],
        leadingIndex: Int,
        leadingWeight: Double,
    ) -> [WeightedChild] {
        let trailingIndex = leadingIndex + 1
        guard children.indices.contains(leadingIndex), children.indices.contains(trailingIndex),
              case let .flex(lead) = children[leadingIndex].weight,
              case let .flex(trail) = children[trailingIndex].weight
        else { return children }

        let pairSum = lead + trail
        // Clamp the requested leading weight into [minWeight, pairSum - minWeight] so BOTH stay ≥ floor and the
        // sum is preserved. Ordered min/max (NaN-faithful): a NaN request floors at minWeight.
        let upper = Double.maximum(pairSum - SplitWeight.minWeight, SplitWeight.minWeight)
        let newLead = Double.minimum(Double.maximum(leadingWeight, SplitWeight.minWeight), upper)
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
