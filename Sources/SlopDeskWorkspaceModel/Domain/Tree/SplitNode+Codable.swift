// MARK: - Codable for SplitWeight (readable {flex:…} / {fixed:…} discriminator)

// A synthesized enum-with-associated-value Codable would emit an opaque nested shape; this hand-written
// pair gives the persisted weight a self-describing `{"flex": 1}` / `{"fixed": 100}` object (docs/42 wire
// shape, mirroring the readable Canvas wire shapes). The DECODE clamps via `repaired()` so a corrupt /
// hand-edited weight (NaN, 0, negative) can never reach the solver.
public extension SplitWeight {
    private enum CodingKeys: String, CodingKey { case flex, fixed }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Validate-then-repair: a weight value of the WRONG type (e.g. a `"nan"` string where a number
        // is expected, or a non-finite literal) must NOT fail the whole tree decode — fold any per-value
        // type mismatch into the equal-share default. `try?` so a malformed value yields `nil`, not a
        // throw that propagates up and bricks the load.
        if container.contains(.flex) {
            let w = (try? container.decode(Double.self, forKey: .flex)) ?? Double.nan
            self = Self.flex(w).repaired() // .repaired() clamps NaN/≤0 to minWeight
        } else if container.contains(.fixed) {
            let p = (try? container.decode(Double.self, forKey: .fixed)) ?? 0
            self = Self.fixed(p).repaired()
        } else {
            // Neither discriminator present → default to an equal flex share.
            self = .flex(1)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .flex(w): try container.encode(w, forKey: .flex)
        case let .fixed(p): try container.encode(p, forKey: .fixed)
        }
    }
}

// MARK: - Codable for SplitNode (defensive, validate-then-repair)

/// ``SplitNode`` IS part of the persistence format (it is a ``Tab``'s `root`), and a corrupt / older /
/// hand-edited file must **repair, never trap** (CLAUDE.md "validate-then-repair on untrusted persisted
/// data"; mirrors the legacy `PaneNode+Codable` `children.count >= 2` guard and the `Canvas` decoder).
///
/// The wire shape is a one-key discriminator object — `{"leaf": "<uuid>"}` or
/// `{"split": {"id": …, "axis": …, "children": […]}}` — so the JSON is self-describing and reviewable
/// under `.sortedKeys`/`.prettyPrinted`.
///
/// `decodeRaw` fills before it reads: a split's `id` or `axis` that is absent or unreadable becomes a
/// fresh id / `.horizontal` rather than failing the load, because a divider group that lost its name
/// still describes a real arrangement (see the note at that line for the `decodeIfPresent` trap).
///
/// On decode, `normalized()` then runs the full repair pass:
/// 1. **Depth cap** — anything nested past ``SplitNode/maxDepth`` collapses to its first leaf.
/// 2. **Drop empty splits** — a `.split` with no valid children is removed.
/// 3. **Collapse single-child splits** — a 1-child `.split` becomes that child.
/// 4. **Flatten same-axis children** — a child `.split` sharing the parent's axis is spliced in (Zellij
///    merge), so the tree never carries a redundant intermediary.
/// 5. **Re-mint duplicate `PaneID`s** — a leaf id already seen is replaced with a fresh one (the
///    registry is keyed 1:1 by `PaneID`).
/// 6. **Clamp weights** — handled in `SplitWeight.init(from:)` (≥ ``SplitWeight/minWeight``, finite).
///
/// **Decode-time stack safety is provided by JSONDecoder, NOT the ``SplitNode/maxDepth`` cap.** The raw
/// `decodeRaw` recursion runs *before* `normalized()` applies the cap, so the cap alone would not stop a
/// pathologically-nested hand-edited file from blowing the stack during decode. It does not have to:
/// `JSONDecoder` enforces its OWN container-nesting bound (~512 levels) and rejects anything deeper with
/// a clean `DecodingError` — the parser unwinds before the recursion can get pathological. So a hostile
/// deep file (or a structurally invalid node with neither discriminator) throws a clean decode error and
/// `WorkspacePersistence.load()` falls back to the default (+ `.corrupt` sidecar) — it never traps. The
/// `maxDepth` cap is purely a *post-decode* repair, bounding the kept structure (so render/solver/ops
/// recursion stays shallow), within whatever JSONDecoder already admitted. (Pinned by
/// `SplitNodeCodableTests.testPathologicallyDeepJSONFailsSoftWithoutStackOverflow`.)
extension SplitNode: Codable {
    private enum CodingKeys: String, CodingKey { case leaf, split }
    private enum SplitKeys: String, CodingKey { case id, axis, children }

    public init(from decoder: any Decoder) throws {
        let raw = try Self.decodeRaw(from: decoder)
        // Repair from the root. `seen` carries the running set of accepted PaneIDs so duplicates across
        // the WHOLE tree (not just within one split) are re-minted.
        var seen: Set<PaneID> = []
        self = raw.normalized(depth: 0, seen: &seen) ?? .leaf(PaneID())
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .leaf(id):
            try container.encode(id, forKey: .leaf)
        case let .split(id, axis, children):
            var split = container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try split.encode(id, forKey: .id)
            try split.encode(axis, forKey: .axis)
            try split.encode(children, forKey: .children)
        }
    }

    /// Decodes the RAW (un-repaired) tree off the wire — no invariant enforcement, just shape. The
    /// repair runs afterwards on the decoded value. Throws on a structurally invalid node.
    private static func decodeRaw(from decoder: any Decoder) throws -> SplitNode {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(PaneID.self, forKey: .leaf) {
            return .leaf(id)
        }
        if container.contains(.split) {
            let split = try container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            // An id or an axis that is missing OR unreadable is FILLED, never a fault: the structure
            // is intact, and a divider group that lost its name still describes a real arrangement.
            // The same answer `slopdesk_workspace::persist::decode_raw_node` gives (`Some("vertical")
            // => Vertical, _ => Horizontal`, and a non-uuid id reads as absent), and the same `try?`
            // idiom `SplitWeight.init(from:)` above already uses on a value of the wrong type.
            //
            // `decodeIfPresent` was the trap. On a key that is PRESENT with a value its type refuses
            // — `"axis": "diagonal"`, `"id": 7` — it does not answer `nil`, it THROWS
            // `DecodingError.dataCorrupted`, so the `??` default written right next to it never ran.
            // One typo in a hand-edited file then threw out of the entire `TreeWorkspace` decode,
            // `WorkspacePersistence.load()` fell back to the default workspace and wrote a `.corrupt`
            // sidecar: the user lost the WHOLE arrangement over one word. Rust repaired it and Swift
            // bricked it; Rust was right, and this file's own header says "repair, never trap".
            //
            // Rejected: a tolerant `SplitAxis.init(from:)`. The tolerance belongs to this READER of a
            // file a person can edit, not to the type — the same axis arriving in an intent from a
            // network peer is a fault the wire codec must still refuse rather than guess at.
            let id = (try? split.decode(SplitNodeID.self, forKey: .id)) ?? SplitNodeID()
            let axis = (try? split.decode(SplitAxis.self, forKey: .axis)) ?? .horizontal
            return try .split(id: id, axis: axis, children: decodeChildren(of: split))
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "SplitNode: object has neither a 'leaf' nor a 'split' discriminator",
        ))
    }

    /// The children of a split: a TOLERANT container wrapped around STRICT elements.
    ///
    /// Two different questions, answered two different ways on purpose:
    ///
    /// - The `children` VALUE being absent, or being present as something that is not an array,
    ///   reads as "no children" — what `slopdesk_workspace::persist::decode_raw_node` answers with
    ///   `.and_then(Json::array).unwrap_or_default()`. `decodeIfPresent([RawWeightedChild].self, …)`
    ///   was the same trap as the id and the axis above: a present-but-wrong-shaped value THROWS
    ///   past the `??`, and the throw cost the user the whole `TreeWorkspace` plus a `.corrupt`
    ///   sidecar.
    /// - A child that IS in the array still decodes strictly, and anything it throws propagates. A
    ///   malformed element is an error in Rust too ("a split child has no node"), and it has to
    ///   be: a `try?` here would drop one pane out of an otherwise decodable arrangement and report
    ///   success. A pane that silently vanishes is worse than a load that visibly refuses.
    ///
    /// What the tolerant container COSTS, stated rather than sold as free: an unreadable `children`
    /// leaves the split empty, `normalized()` drops an empty split, and if that split was the tab's
    /// root the tab comes back as one fresh blank pane. The malformed value described no panes to
    /// begin with — there is nothing under a `5` to recover — so what is actually lost is the seam,
    /// and at the root the tab's arrangement. Bounded to one subtree, where the throw it replaces
    /// cost every session, tab and split in the file.
    private static func decodeChildren(of split: KeyedDecodingContainer<SplitKeys>) throws -> [WeightedChild] {
        guard var unkeyed = try? split.nestedUnkeyedContainer(forKey: .children) else { return [] }
        var children: [WeightedChild] = []
        // WeightedChild decodes recursively (each `node` re-enters decodeRaw via its own init).
        while !unkeyed.isAtEnd {
            try children.append(unkeyed.decode(RawWeightedChild.self).child)
        }
        return children
    }
}

// MARK: - Raw (un-repaired) child decode

// During `decodeRaw`, a child's `node` must decode WITHOUT triggering the repairing `SplitNode.init` —
// otherwise repair would run bottom-up per node and the depth cap / cross-tree dup detection couldn't be
// applied once from the root. `RawWeightedChild` decodes the same wire shape into a plain `WeightedChild`
// using `decodeRaw`, deferring all repair to the single top-level `normalized()` pass.
private struct RawWeightedChild: Decodable {
    let child: WeightedChild

    private enum CodingKeys: String, CodingKey { case weight, node }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The weight is the one field a repair can invent a right answer for, so an unreadable one
        // folds to the equal share rather than failing the load — `decode_weight`'s trailing
        // `SplitWeight::Flex(1.0)`. `SplitWeight.init(from:)` is already tolerant of a wrong-TYPED
        // value under a key, but it cannot help when the weight is not an object at all
        // (`"weight": 5`): its `container(keyedBy:)` throws before any of its own `try?`s run, and
        // `decodeIfPresent` propagated that straight past the `?? .flex(1)` written next to it. A
        // lost divider position costs one drag; the throw it replaces cost the whole file.
        let weight = (try? container.decode(SplitWeight.self, forKey: .weight)) ?? .flex(1)
        // Decode the node's RAW shape (no repair) via a nested decoder.
        let nodeDecoder = try container.superDecoder(forKey: .node)
        let node = try SplitNode.rawNode(from: nodeDecoder)
        child = WeightedChild(weight: weight, node: node)
    }
}

private extension SplitNode {
    /// Bridges into the private `decodeRaw` from `RawWeightedChild` (which is file-private here too).
    static func rawNode(from decoder: any Decoder) throws -> SplitNode {
        try decodeRaw(from: decoder)
    }
}

// MARK: - The repair pass (pure)

private extension SplitNode {
    /// Returns a repaired copy with every ``SplitNode`` invariant held, or `nil` if this subtree is
    /// degenerate (an empty split) and should be removed by its parent. `depth` is the current nesting
    /// level (root = 0); `seen` accumulates accepted ``PaneID``s so a duplicate ANYWHERE in the tree is
    /// re-minted. Pure (apart from minting fresh ids — deterministic given the dup set).
    func normalized(depth: Int, seen: inout Set<PaneID>) -> SplitNode? {
        switch self {
        case let .leaf(id):
            // Re-mint a duplicate so the registry's 1:1 keying holds; the FIRST occurrence keeps its id.
            if seen.contains(id) {
                var fresh = PaneID()
                while seen.contains(fresh) { fresh = PaneID() }
                seen.insert(fresh)
                return .leaf(fresh)
            }
            seen.insert(id)
            return .leaf(id)

        case let .split(id, axis, children):
            // Depth cap: past maxDepth, collapse this whole subtree to its first surviving leaf so the
            // tree stays bounded and the recursion can't blow the stack. (depth is 0-based; a split at
            // depth maxDepth-1 would put its leaves at maxDepth, which is still allowed.)
            if depth >= Self.maxDepth - 1 {
                return firstLeaf(seen: &seen)
            }

            // Recurse into each child, dropping degenerate (nil) subtrees, and FLATTEN any child split
            // that shares this axis (Zellij merge) so no redundant same-axis intermediary survives.
            var repaired: [WeightedChild] = []
            for child in children {
                guard let node = child.node.normalized(depth: depth + 1, seen: &seen) else { continue }
                if case let .split(_, childAxis, grandchildren) = node, childAxis == axis {
                    repaired.append(contentsOf: grandchildren) // splice the grandchildren in
                } else {
                    repaired.append(WeightedChild(weight: child.weight.repaired(), node: node))
                }
            }

            switch repaired.count {
            case 0:
                return nil // empty split → tell the parent to drop it
            case 1:
                return repaired[0].node // single-child split → collapse into the child
            default:
                return .split(id: id, axis: axis, children: repaired)
            }
        }
    }

    /// The first leaf of this subtree (DFS), accounting for the running `seen` dup set so a collapsed
    /// over-deep tail still respects unique-id repair. A split with no leaf yields a freshly minted leaf
    /// (the tree is never empty after repair).
    func firstLeaf(seen: inout Set<PaneID>) -> SplitNode {
        switch self {
        case let .leaf(id):
            if seen.contains(id) {
                var fresh = PaneID()
                while seen.contains(fresh) { fresh = PaneID() }
                seen.insert(fresh)
                return .leaf(fresh)
            }
            seen.insert(id)
            return .leaf(id)
        case let .split(_, _, children):
            for child in children {
                return child.node.firstLeaf(seen: &seen)
            }
            let fresh = PaneID()
            seen.insert(fresh)
            return .leaf(fresh)
        }
    }
}
