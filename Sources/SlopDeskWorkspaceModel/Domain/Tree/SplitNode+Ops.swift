import CSlopDeskFFI

// MARK: - Pure split-tree operations (docs/42 §"Pure ops" — SplitNode+Ops.swift)

/// Pure transformations on the recursive ``SplitNode`` tree: each returns a NEW tree, never mutates in
/// place, and preserves the tree invariants (≥ 2 children per split, no redundant same-axis nesting,
/// finite ≥ ``SplitWeight/minWeight`` flex weights). No I/O, no GUI.
///
/// Every rule is `rust/slopdesk-workspace`'s `split_tree` (docs/55). What crosses is the tree's
/// PRE-ORDER walk in BOTH directions — see ``WsTree`` for why that rather than the persisted JSON.
///
/// ### The crate mints nothing
/// A split created by ``splitting(_:axis:inserting:before:)`` needs a fresh ``SplitNodeID``, and the
/// crate refuses to invent one: `identity.rs` holds every identity to being SUPPLIED, so that a
/// replay or a test can pin it. The id is therefore minted here and passed in, which is why these
/// three signatures are unchanged for their callers while the rule underneath them moved.
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
        let fresh = SplitNodeID()
        return WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_splitting(
                nodes.baseAddress,
                nodes.count,
                target.ffi,
                axis.ffiByte,
                newLeaf.ffi,
                before,
                SlopDeskWsUuid(fresh.raw),
                out,
                cap,
            )
        }
    }

    // MARK: Insert an existing leaf beside another

    /// Inserts the EXISTING leaf `leaf` beside `target` along `axis` — the drag-to-dock gesture, where
    /// nothing is created and a pane merely changes neighbours. `nil` when `target` is not in this tree.
    func inserting(_ leaf: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) -> SplitNode? {
        let fresh = SplitNodeID()
        return WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_inserting_beside(
                nodes.baseAddress,
                nodes.count,
                leaf.ffi,
                target.ffi,
                axis.ffiByte,
                before,
                SlopDeskWsUuid(fresh.raw),
                out,
                cap,
            )
        }
    }

    /// Docks `leaf` against the whole tree's leading (`before`) or trailing edge along `axis` — the
    /// drop-on-the-container-border half of the same gesture. Always applies.
    func insertingAtRoot(_ leaf: PaneID, axis: SplitAxis, before: Bool) -> SplitNode {
        let fresh = SplitNodeID()
        return WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_inserting_at_root(
                nodes.baseAddress,
                nodes.count,
                leaf.ffi,
                axis.ffiByte,
                before,
                SlopDeskWsUuid(fresh.raw),
                out,
                cap,
            )
        } ?? self
    }

    // MARK: Remove a leaf

    /// Closes leaf `target`, its siblings dividing the space it held and any split left with one child
    /// collapsing into that child. `nil` when `target` was the tree's LAST leaf — the tab is then empty,
    /// which is the caller's decision to act on rather than something a tree can represent.
    func removing(_ target: PaneID) -> SplitNode? {
        WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_removing(nodes.baseAddress, nodes.count, target.ffi, out, cap)
        }
    }

    // MARK: Dividers

    /// Drags the divider after `leadingIndex` in split `splitID` by `delta` points' worth of weight, the
    /// two children either side of it trading the difference. Identity when the split is not here.
    func resizingDivider(splitID: SplitNodeID, leadingIndex: Int, delta: Double) -> SplitNode {
        WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_resizing_divider(
                nodes.baseAddress,
                nodes.count,
                SlopDeskWsUuid(splitID.raw),
                leadingIndex,
                delta,
                out,
                cap,
            )
        } ?? self
    }

    /// Evens ONE seam — the pair either side of it take their mean. Every other divider in the tree keeps
    /// its position, which is what makes this a different gesture from ``rebalanced()``.
    func eveningDivider(splitID: SplitNodeID, leadingIndex: Int) -> SplitNode {
        WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_evening_divider(
                nodes.baseAddress,
                nodes.count,
                SlopDeskWsUuid(splitID.raw),
                leadingIndex,
                out,
                cap,
            )
        } ?? self
    }

    /// Sets the ABSOLUTE leading weight of the divider after `leadingIndex`, the trailing sibling taking
    /// the remainder — the cursor-matched form a live divider drag uses, where a delta would accumulate
    /// error across the gesture.
    func settingDividerWeight(splitID: SplitNodeID, leadingIndex: Int, leadingWeight: Double) -> SplitNode {
        WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_setting_divider_weight(
                nodes.baseAddress,
                nodes.count,
                SlopDeskWsUuid(splitID.raw),
                leadingIndex,
                leadingWeight,
                out,
                cap,
            )
        } ?? self
    }

    // MARK: Swap and map

    /// Exchanges the positions of two panes, every weight staying where it was — the panes move, the
    /// layout does not. Identity when either is absent or they are the same pane.
    func swapping(_ a: PaneID, _ b: PaneID) -> SplitNode {
        WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_swapping(nodes.baseAddress, nodes.count, a.ffi, b.ffi, out, cap)
        } ?? self
    }

    /// Returns a tree with every leaf id passed through `transform` (structure + weights unchanged). Pure.
    ///
    /// Stays Swift: the rule IS the caller's closure, and flattening it the way ``TabOrdering`` flattens
    /// its key function would mean pre-evaluating a mapping over every leaf just to rebuild the same tree
    /// on the other side. A structural rewrite with a caller-supplied body is a container walk, not a
    /// decision — so it walks here.
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
    /// contains the pane (e.g. a sole leaf, or the pane only sits under the other axis).
    ///
    /// "Nearest" = the DEEPEST matching ancestor: a keyboard width-resize should nudge the divider closest
    /// to the active pane.
    func enclosingSplit(of pane: PaneID, axis: SplitAxis) -> (splitID: SplitNodeID, childIndex: Int, childCount: Int)? {
        var nodes = WsTree.walk(self)
        var answer = SlopDeskWsEnclosing()
        let found = nodes.withUnsafeMutableBufferPointer { walk in
            slopdesk_ws_tree_enclosing_split(walk.baseAddress, walk.count, pane.ffi, axis.ffiByte, &answer)
        }
        guard found else { return nil }
        return (SplitNodeID(raw: answer.split.uuid), answer.child_index, answer.child_count)
    }

    // MARK: Rebalance (tmux even-layout)

    /// This subtree with every `.split`'s `.flex` children reset to an EQUAL `.flex(1)` share (recursively),
    /// while `.fixed` children keep their points. The tree SHAPE and the leaf set/order are unchanged — only
    /// the flex weights are equalized (the tmux "select-layout even-*" idiom).
    func rebalanced() -> SplitNode {
        WsTree.op(self) { nodes, out, cap in
            slopdesk_ws_tree_rebalanced(nodes.baseAddress, nodes.count, out, cap)
        } ?? self
    }

    // MARK: Locate

    /// The first leaf of the tree in pre-order DFS (the sensible default focus / the "first survivor"). A
    /// tree always has ≥ 1 leaf, so this is never `nil` for a real tree.
    var firstLeafID: PaneID? {
        var nodes = WsTree.walk(self)
        var answer = SlopDeskWsUuid()
        let found = nodes.withUnsafeMutableBufferPointer { walk in
            slopdesk_ws_tree_first_leaf(walk.baseAddress, walk.count, &answer)
        }
        return found ? PaneID(ffi: answer) : nil
    }

    // MARK: Compare

    /// Structural equality that IGNORES ``SplitNodeID``s: two trees are structurally equal iff they have the
    /// same shape (axis + ordered children count), the same leaf ids in the same positions, and the same
    /// weights. The synthesized `==` includes the split id, so a rebuild that reproduces the same
    /// arrangement under a freshly-minted id looks "changed" to `!=`; a relocate uses this to detect a true
    /// no-op drop (drop a pane where it already sits) and skip the reconcile/save churn. Pure.
    ///
    /// The walk carries each split's id like every other tree door's does; it is the crate's
    /// `is_structurally_equal` that declines to read them, so the two trees compare by the arrangement
    /// alone whichever caller asks.
    func isStructurallyEqual(to other: SplitNode) -> Bool {
        var lhs = WsTree.walk(self)
        var rhs = WsTree.walk(other)
        return lhs.withUnsafeMutableBufferPointer { left in
            rhs.withUnsafeMutableBufferPointer { right in
                slopdesk_ws_tree_structurally_equal(
                    left.baseAddress, left.count, right.baseAddress, right.count,
                )
            }
        }
    }
}

extension SplitAxis {
    /// The axis as the byte that crosses the ABI. Vertical is 1; everything else reads as horizontal,
    /// which is the arrangement a split makes when nobody said otherwise.
    var ffiByte: UInt8 { self == .vertical ? 1 : 0 }
}
